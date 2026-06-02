# Office Plants — Automated Irrigation Service

Self-contained service that keeps 4 office plants watered: a **PricelessToolkit "Droplet"**
ESP32 controller measures soil moisture and runs a pump per plant when the soil is too dry,
with thresholds and per-plant run-times configured in **Home Assistant**.

- **Owner:** Rasmus (homelab)
- **Status:** in service (4 plants live)
- **Source of truth:** this repo
  - Firmware/config: [`esphome/config/droplettest.yaml`](../../esphome/config/droplettest.yaml)
  - HA helpers: [`homeassistant/ha-config/packages/irrigation.yaml`](../../homeassistant/ha-config/packages/irrigation.yaml)
  - HA dashboard: [`homeassistant/ha-config/dashboards/home.yaml`](../../homeassistant/ha-config/dashboards/home.yaml)

---

## 1. What it does

Every **15 min during the day (08:00–21:00 local)**, the Droplet checks each plant:
if `soil_moisture% < desired%` it runs that plant's pump for its configured number of
seconds, soaks ~10 s, then moves to the next plant (one pump at a time). All four thresholds
and run-times are set from Home Assistant; nothing waters at night, and a master
**Auto Watering** switch (plus a manual **Water Now** button) is exposed in HA.

Decision + timing logic runs **on the device** (ESPHome), so it keeps its last-known
thresholds in RAM and only *needs* Home Assistant to (re)read configuration — see
[Dependencies](#4-dependencies).

---

## 2. Architecture (C4)

### Level 1 — System context

```mermaid
flowchart TB
    gardener([Gardener / office occupant])
    plants([4 office plants])
    subgraph svc["Office Plants Irrigation Service"]
      droplet["Droplet controller<br/>(ESP32, 4 pumps, 4 soil sensors)"]
    end
    ha["Home Assistant<br/>thresholds, run-times, dashboard, clock peer"]
    wifi["WiFi — SSID 'Walther'<br/>(Ubiquiti APs)"]
    ntp["NTP<br/>(OPNsense 192.168.2.1)"]

    gardener -->|sets thresholds & run-times,<br/>watches soil %| ha
    droplet -->|reads desired moisture<br/>+ per-plant seconds| ha
    droplet -->|local time for day/night guard| ntp
    droplet -. associates .-> wifi
    droplet ==>|pumps water| plants
    plants -. moisture sensed .-> droplet
```

### Level 2 — Containers / deployment

```mermaid
flowchart TB
    subgraph office["Physical (office)"]
      droplet["**Droplet** ESP32 @ 192.168.2.245<br/>ESPHome firmware<br/>pumps 1-4, soil 1-4, OLED, buzzer"]
      pumps["4 pumps + soaker hoses"]
      sensors["4 capacitive soil sensors"]
      reservoir["Water reservoir"]
      droplet --> pumps --> reservoir
      sensors --> droplet
    end

    subgraph net["Network (OPNsense 192.168.2.1 / 26.1.8)"]
      aps["Ubiquiti APs — SSID 'Walther'"]
      ntpd["NTP server"]
      haproxy["HAProxy + ACME<br/>homeassistant.teststuff.net"]
    end

    subgraph cluster["Talos k8s cluster on Proxmox 'pve' (192.168.2.3)"]
      ha["**Home Assistant** pod (ns home-assistant)<br/>VIP 192.168.40.10:8123 (Cilium BGP)<br/>hostPath PV on wk-01"]
      irr["irrigation package:<br/>input_number.moisture_level_for_pumpN<br/>input_number.watering_seconds_pumpN"]
      ha --- irr
    end

    popos["pop-os 192.168.2.10<br/>ESPHome dashboard :6052<br/>(firmware builds/flash)"]

    droplet -. WiFi .-> aps
    droplet -->|SNTP| ntpd
    droplet <-->|ESPHome native API :6053<br/>encrypted| ha
    popos -. OTA :3232 .-> droplet
    haproxy --> ha
```

### Physical setup
The Droplet sits **on top of the water-reservoir box**, slightly elevated, so any pump or
hose leak **drains back into the reservoir** rather than onto the floor. Pumps draw from this
same box (short lift), feeding the 4 soaker hoses into the pots.

### What is deployed where

| Component | Where | Address | Notes |
|---|---|---|---|
| Droplet controller | Office, mains/USB powered | `192.168.2.245` (`droplettest`, MAC `30:c6:f7:22:a8:fc`) | ESP32 `esp32dev`, ESPHome; always-on (no deep sleep) |
| Pumps 1–4 | Droplet board outputs | GPIO 13 / 4 / 16 / 17 | one per plant, via soaker hoses |
| Soil sensors 1–4 | Droplet ADC inputs | GPIO 34 / 35 / 32 / 33 | capacitive; calibrated dry 2.30 V→0 %, water 0.89 V→100 % |
| Home Assistant | k8s (Talos) on Proxmox `pve` | VIP `192.168.40.10:8123`, `https://homeassistant.teststuff.net` | thresholds, run-times, dashboard, time peer |
| HA config (package + dashboard) | git → HA `/config` PV | `homeassistant/ha-config/...` | applied via `kubectl cp` + reload/restart |
| WiFi | Ubiquiti APs | SSID `Walther` | controller on dead T61; APs run standalone (see [Risks](#7-risk-analysis)) |
| NTP | OPNsense | `192.168.2.1` (+ `pool.ntp.org` fallback) | used for the day/night guard |
| ESPHome dashboard | pop-os | `192.168.2.10:6052` | build + flash firmware |

---

## 3. Configuration

All runtime tuning is in Home Assistant (dashboard card **"Watering time per plant"** and
**"Desired moisture thresholds"**), backed by `irrigation.yaml`:

| Setting | Entity | Range | Meaning |
|---|---|---|---|
| Desired moisture | `input_number.moisture_level_for_pump1..4` | 0–100 % | water while `soil% < this` |
| Run time per plant | `input_number.watering_seconds_pump1..4` | 5–600 s | how long that pump runs each pass |
| Master enable | `switch.droplettest_droplet_auto_watering` | on/off | default off after fresh flash; restores last state on reboot |
| Manual one-shot | `button.droplettest_droplet_water_now` | press | runs one cycle ignoring auto/daytime (still only waters below-threshold plants) |

Behaviour constants (less-often changed) live as `substitutions:` at the top of
`droplettest.yaml`: `check_interval` (15 min), `soak_seconds` (10 s), `day_start`/`day_end`
(8/21), `watering_seconds` (60 s fallback only).

> **Note:** the HA helpers intentionally have **no `initial:`** value, so they *persist*
> across HA restarts (a restart with `initial:` set silently resets them).

> **Note:** desired moisture and run-times are read from HA over the encrypted ESPHome API.
> If HA is unreachable those values are `NaN` and **no watering happens** (fail-safe).

### Bigger pots / weak pumps / soaker-hose priming
Pumps are underpowered for the larger pots, and soaker hoses absorb the first part of each
run before dripping. Compensate by **raising `watering_seconds_pumpN`** (up to 600 s) for the
thirsty pots — no reflash needed, it's a slider.

---

## 4. Dependencies

```mermaid
flowchart LR
    water["Can it auto-water?"]
    power["Droplet power"]
    wifi["WiFi (Ubiquiti AP)"]
    ntp["NTP (OPNsense)"]
    ha["Home Assistant"]
    k8s["Talos cluster"]
    pve["Proxmox 'pve'"]

    water --> power
    water --> wifi
    water --> ntp
    water --> ha
    ha --> k8s --> pve
```

| Dependency | Needed for | If it fails |
|---|---|---|
| **Droplet power** | everything | no watering, no monitoring |
| **WiFi (`Walther`, Ubiquiti AP)** | device connectivity | device offline; APs run standalone even if the controller is down |
| **NTP (OPNsense `.1` / pool)** | day/night guard (auto only) | clock invalid → daytime guard fails closed → **no auto watering** (manual Water Now still works) |
| **Home Assistant** | thresholds + run-times | values go `NaN` → **no watering at all** (fail-safe) |
| **Talos k8s + Proxmox `pve`** | hosting Home Assistant | HA down → see above |
| **ESPHome dashboard (pop-os)** | firmware changes only | no runtime impact |

Local-first: NTP and the cluster are on-LAN, so watering does **not** depend on the internet
(public NTP is only a fallback).

---

## 5. Operations — routine

| Task | How |
|---|---|
| Change a threshold / run-time | HA dashboard sliders |
| Water immediately | press **Water Now** in HA |
| Stop everything | turn **Auto Watering** off (and/or set thresholds to 0) |
| Check soil readings | HA → Plant 1–4 sensors, or device `soilm_sens_N` |
| Read raw sensor voltage | device diagnostic sensors `soilN_raw` (hidden by default; enable in HA or read via API) |
| View logs | ESPHome dashboard (`192.168.2.10:6052`) → Logs, or `esphome logs` |
| Update firmware | edit `droplettest.yaml` → OTA (see below) |

### Firmware update / OTA
From a machine with the repo + ESPHome (or the dashboard at `192.168.2.10:6052`):
```bash
# esphome/config/secrets.yaml (gitignored) must hold wifi_ssid / wifi_password / ota_password
esphome run esphome/config/droplettest.yaml --device 192.168.2.245
```
- **OTA password** is recorded at `~/.claude/homelab-droplet/ota_password`.
- If OTA auth ever fails: block the device in UniFi → it starts its fallback AP → upload the
  built `.bin` via the captive portal (`http://192.168.4.1`). USB-UART is the last resort.

---

## 6. Maintenance — hardware

### Replace a pump
1. **Auto Watering → off** in HA (prevents a cycle starting mid-swap).
2. Empty the line / lift the hose out of the pot to avoid spillage.
3. Disconnect the failed pump from its Droplet output terminal and its tubing.
4. Fit the replacement pump to the **same** terminal + tubing (match polarity/voltage).
5. No config change — the GPIO mapping is unchanged (`pump1=13, pump2=4, pump3=16, pump4=17`).
6. Test: HA → toggle `switch.droplettest_droplet_pump_N` on for a few seconds (or press
   **Water Now** with that plant below threshold) and confirm flow.
7. Auto Watering → on.

### Replace a moisture sensor
1. Unplug the failed capacitive sensor from its channel header; plug the new one into the
   **same** channel (`Soil1=GPIO34, Soil2=35, Soil3=32, Soil4=33`).
2. **Recalibrate that channel** — sensors vary unit-to-unit (see below). This is required;
   skipping it gives wrong % and bad watering decisions.

### Recalibrate a soil sensor (per channel)
Calibration maps ADC volts → %. Defaults: dry `2.30 V → 0 %`, water `0.89 V → 100 %`.
1. In HA enable the `Soil N raw` diagnostic sensor (or read `soilN_raw` over the API) — it
   reports the **actual voltage**.
2. Put the sensor in **dry** soil/air → note `soilN_raw` (e.g. `2.30 V`).
3. Put the sensor in **plain water** → note `soilN_raw` (e.g. `0.89 V`).
4. Edit that sensor's `calibrate_linear` in `droplettest.yaml`:
   ```yaml
   filters:
     - calibrate_linear:
         - <dry_V> -> 0.00
         - <wet_V> -> 100.00
     - clamp: { min_value: 0, max_value: 100 }
   ```
5. OTA flash (see above). Verify dry reads ~0 %, water ~100 %.

> Why this matters: a 2-point linear fit is approximate (capacitive sensors are slightly
> non-linear), so treat mid-range % as a guide. The `soilN_raw` readout makes recalibration
> a "read the voltage" job rather than guesswork.

---

## 7. Risk analysis

| # | Risk | Likelihood | Impact | Mitigation / status |
|---|---|---|---|---|
| R1 | **Home Assistant down** (cluster/Proxmox/storage) → device can't read thresholds → no watering | Medium | High (plants dry out) | Fail-safe (no false watering); HA on cluster; **next:** HA HA / alerting. Single hostPath PV on wk-01 is a SPOF |
| R2 | **Reservoir runs empty / pump runs dry** | High | High | Manual refill checks; **no level sensor yet** → see Next steps |
| R3 | **Pump fails** (weak/dead) — plant silently not watered | Medium | Medium | "soil not rising after watering" is the tell; **next:** auto-detect & alert |
| R4 | **Sensor drift / failure** → over- or under-watering | Medium | Medium | Periodic recalibration; `soilN_raw` diagnostics; clamp 0–100 |
| R5 | **Threshold set higher than soil can reach** → pump runs every cycle (over-water) | Medium | Medium | Pick reachable thresholds; **next:** per-run max + daily cap |
| R6 | **Leak / hose pops off** while pumping | Low | Low–Med | **Droplet sits elevated on the reservoir box → leaks drain back into it**, limiting water damage; daytime-only, short runs. Still no leak/flow detection → Next steps |
| R7 | **WiFi outage** → device offline | Low | Medium | APs run standalone; UniFi controller migration in progress |
| R8 | **NTP unreachable** → daytime guard blocks auto watering | Low | Medium | Local OPNsense NTP + public fallback; manual Water Now unaffected |
| R9 | **Power loss to Droplet** | Low | Medium | Auto Watering restores last state on boot; thresholds persist (no `initial:`) |
| R10 | **Lost OTA / API credentials** → can't manage remotely | Low | Low | OTA pw recorded in `~/.claude/homelab-droplet/`; API key in config; captive-portal/USB fallback |
| R11 | **API encryption key committed in plaintext** in `droplettest.yaml` | Certain | Low (LAN) / High if repo goes public | **Move to `secrets.yaml` before publishing** (see repo PUBLISH-CHECKLIST) |

---

## 8. Next steps

- **Reservoir water-level sensor** + low-water alert (biggest gap — R2).
- **Pump-health detection:** flag a plant whose soil doesn't rise after N waterings (R3).
- **Flow/leak detection** or a hardware max-run fuse (R6).
- **Notifications** (HA): watering events, stale/again-NaN sensors, reservoir low.
- Make **`check_interval` configurable from HA** (like the per-plant seconds) for long-run setups.
- **Per-sensor / multi-point calibration** for better mid-range accuracy.
- **Home Assistant resilience:** real storage provisioner instead of single-node hostPath; HA across nodes.
- **Move the API encryption key to `secrets.yaml`** (R11) ahead of making the repo public.
- Optional: graph soil %, watering count, and run-time per plant for trend visibility.

---

## 9. Quick reference

| Item | Value |
|---|---|
| Device IP / host | `192.168.2.245` / `droplettest` |
| ESPHome API | `:6053` (encrypted; key in `droplettest.yaml`) |
| OTA | `:3232`; password in `~/.claude/homelab-droplet/ota_password` |
| WiFi SSID | `Walther` (secrets in `esphome/config/secrets.yaml`, gitignored) |
| Pumps | `pump1=GPIO13, pump2=GPIO4, pump3=GPIO16, pump4=GPIO17` |
| Soil sensors | `Soil1=GPIO34, Soil2=GPIO35, Soil3=GPIO32, Soil4=GPIO33` |
| Time | SNTP `192.168.2.1` + `pool.ntp.org`, TZ Europe/Tallinn |
| Home Assistant | `https://homeassistant.teststuff.net` / `192.168.40.10:8123` |
| ESPHome dashboard | `http://192.168.2.10:6052` |
| HA package / dashboard | `homeassistant/ha-config/packages/irrigation.yaml`, `.../dashboards/home.yaml` |
