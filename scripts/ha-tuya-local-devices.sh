#!/usr/bin/env bash
# Create one tuya_local config entry per Tuya device, from the wallet material (FU-038).
#
# Idempotent: skips any device_id that already has an entry, so it is safe to re-run after adding
# a device or after a wallet refresh.
#
# WHY SCRIPTED. The runbook says the CLOUD Tuya integration is not scriptable (it needs the Smart
# Life QR login in the UI). tuya_local is the opposite: its config flow takes host + device_id +
# local_key + protocol version, all of which we hold, so the whole thing drives over the config-flow
# REST API. That matters beyond convenience — hand-typing a 16-char local_key seven times is exactly
# the sort of step that fails silently and gets blamed on the device.
#
# Input:  ~/.claude/tuya/devices.json  (materialized from the wallet by scripts/wallet-files.sh)
# Needs:  ha-access-token in the wallet (docs/runbook.md §Home Assistant)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HA="${HA_URL:-https://homeassistant.teststuff.net}"
DEVFILE="${TUYA_DEVICES:-$HOME/.claude/tuya/devices.json}"
[ -f "$DEVFILE" ] || { echo "missing $DEVFILE — run: bash scripts/wallet-files.sh" >&2; exit 1; }

KP_DIR=""
for d in "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
  [ -f "$d/homelab.kdbx" ] && KP_DIR="$d" && break
done
[ -n "$KP_DIR" ] || { echo "wallet not found" >&2; exit 1; }
kp() { if command -v keepassxc-cli >/dev/null 2>&1; then keepassxc-cli "$@"; else
        (cd "$ROOT" && devbox run --quiet -- keepassxc-cli "$@"); fi; }
TOKEN="${HA_TOKEN:-$(kp show -q --no-password -k "$KP_DIR/homelab.keyx" -a Password "$KP_DIR/homelab.kdbx" ha-access-token 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "could not read ha-access-token from the wallet" >&2; exit 1; }

HA_URL="$HA" HA_TOKEN="$TOKEN" DEVFILE="$DEVFILE" python3 - <<'PY'
import json, os, urllib.request, urllib.error, time

HA=os.environ["HA_URL"]; TOK=os.environ["HA_TOKEN"]
devs=json.load(open(os.environ["DEVFILE"]))["devices"]

def api(path, body=None, method=None):
    req=urllib.request.Request(f"{HA}/api/{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method or ("POST" if body is not None else "GET"),
        headers={"Authorization":f"Bearer {TOK}","Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)

# Which device_ids already have an entry? The flow aborts on duplicates anyway, but skipping keeps
# the output honest about what this run actually changed.
existing=set()
for e in api("config/config_entries/entry"):
    if e.get("domain")=="tuya_local":
        existing.add((e.get("title") or "").strip())

created=skipped=failed=0
for d in devs:
    label=f"tuyalocal {d['powers'].split()[0].split('/')[0]}"
    if label in existing:
        print(f"  = {d['name']:16} already configured as {label!r}"); skipped+=1; continue
    try:
        f=api("config/config_entries/flow", {"handler":"tuya_local"})
        fid=f["flow_id"]
        f=api(f"config/config_entries/flow/{fid}", {"setup_mode":"manual"})
        f=api(f"config/config_entries/flow/{fid}", {
            "device_id":d["device_id"], "host":d["lan_ip"],
            "local_key":d["local_key"], "protocol_version":d["protocol_version"],
            "poll_only":False})
        if f.get("step_id")!="select_type":
            print(f"  ! {d['name']:16} did not reach select_type: {f.get('errors') or f.get('reason')}"); failed+=1; continue
        # Take the AUTO-DETECTED default rather than hardcoding a type: these are three different
        # product families (smartplug / NOUS A1 socket / temp sensor) and tuya_local picks the
        # matching DP map from the device's own response.
        detected=f["data_schema"][0].get("default")
        f=api(f"config/config_entries/flow/{fid}", {"type":detected})
        if f.get("step_id")!="choose_entities":
            print(f"  ! {d['name']:16} unexpected step {f.get('step_id')}: {f.get('errors')}"); failed+=1; continue
        f=api(f"config/config_entries/flow/{fid}", {"name":label})
        if f.get("type")=="create_entry":
            print(f"  + {d['name']:16} -> {label!r}  ({detected.split('||')[0]})"); created+=1
        else:
            print(f"  ! {d['name']:16} {f.get('type')} {f.get('reason') or f.get('errors')}"); failed+=1
        time.sleep(2)
    except urllib.error.HTTPError as e:
        print(f"  ! {d['name']:16} HTTP {e.code}: {e.read()[:120].decode(errors='replace')}"); failed+=1
    except Exception as e:
        print(f"  ! {d['name']:16} {type(e).__name__}: {e}"); failed+=1

print(f"\n  created={created} skipped={skipped} failed={failed}")
raise SystemExit(1 if failed else 0)
PY
