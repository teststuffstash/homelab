#!/usr/bin/env bash
# Self-test for opnsense/drill/config-compare.py (FU-297) — synthetic documents, expected rows
# derived by hand from the tool's header contract (NOT by running it). The drill runs this before
# it scores; run it by hand after editing the tool:  bash opnsense/drill/config-compare-test.sh
set -euo pipefail
cd "$(dirname "$0")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/prod.xml" <<'X'
<opnsense>
  <system><hostname>OPNsense</hostname><timezone>Europe/Tallinn</timezone><extra/></system>
  <OPNsense><HAProxy>
    <backends>
      <backend uuid="11111111-1111-1111-1111-111111111111"><name>be-a</name><id>aaa</id></backend>
    </backends>
    <frontends>
      <frontend uuid="22222222-2222-2222-2222-222222222222"><name>fe-a</name>
        <defaultBackend>11111111-1111-1111-1111-111111111111</defaultBackend><mode>http</mode></frontend>
      <frontend uuid="33333333-3333-3333-3333-333333333333"><name>fe-clicked</name><mode>tcp</mode></frontend>
    </frontends>
  </HAProxy></OPNsense>
  <dnsmasq><hosts uuid="44444444-4444-4444-4444-444444444444"><host>pve</host><ip>192.168.2.3</ip></hosts></dnsmasq>
  <revision><time>1</time></revision>
</opnsense>
X
cat > "$T/drill.xml" <<'X'
<opnsense>
  <system><hostname>opnsense-drill</hostname><timezone>Etc/UTC</timezone><extra></extra></system>
  <OPNsense><HAProxy>
    <backends>
      <backend uuid="99999999-9999-9999-9999-999999999999"><name>be-a</name><id>bbb</id></backend>
    </backends>
    <frontends>
      <frontend uuid="88888888-8888-8888-8888-888888888888"><name>fe-a</name>
        <defaultBackend>99999999-9999-9999-9999-999999999999</defaultBackend><mode>http</mode></frontend>
      <frontend uuid="77777777-7777-7777-7777-777777777777"><name>fe-empty</name></frontend>
    </frontends>
  </HAProxy></OPNsense>
  <dnsmasq><hosts uuid="55555555-5555-5555-5555-555555555555"><host>pve</host><ip>192.168.1.3</ip></hosts></dnsmasq>
  <revision><time>2</time></revision>
</opnsense>
X
cat > "$T/map.txt" <<'X'
# test map
remap     dnsmasq/**   192.168.1.  192.168.2.
env       value        system/hostname
accepted  value        OPNsense/HAProxy/*/*[*]/id
accepted  *            revision/**
accepted  prod-only    never/matches
X

python3 config-compare.py "$T/prod.xml" "$T/drill.xml" --map "$T/map.txt" \
  --json "$T/out.json" --detail "$T/detail.tsv" --report "$T/report.md" --prom "$T/out.prom"

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: expected '$3', got '$2'"; fail=1; fi; }
row() { grep -P "^$1\t$2\t$3\t" "$T/detail.tsv" | wc -l | tr -d ' '; }
# Expected, from the contract:
#  - system/hostname differs → env (map line); system/timezone differs → clickops; <extra/> vs
#    <extra></extra> are both empty → no row.
#  - backend be-a matched BY NAME despite different uuids; its id differs → accepted.
#  - frontend fe-a's defaultBackend holds different uuids that both name backend[be-a] → no row.
#  - fe-clicked is on prod only → ONE clickops row (a keyed item counts once, not per field).
#  - fe-empty is drill-only; its <name> is content (only an item whose every leaf is empty is
#    "absent"), so ONE drill-only clickops row.
#  - dnsmasq hosts[pve]/ip 192.168.1.3 remaps to 192.168.2.3 → env, not clickops.
#  - revision/time → accepted.
check "hostname → env"                       "$(row env value system/hostname)" 1
check "timezone → clickops"                  "$(row clickops value system/timezone)" 1
check "empty vs self-closed → no row"        "$(grep -c 'system/extra' "$T/detail.tsv" || true)" 0
check "uuid-keyed item matched by name"      "$(row accepted value 'OPNsense/HAProxy/backends/backend\[be-a\]/id')" 1
check "uuid reference compared by target"    "$(grep -c defaultBackend "$T/detail.tsv" || true)" 0
check "prod-only item counts once"           "$(row clickops prod-only 'OPNsense/HAProxy/frontends/frontend\[fe-clicked\]')" 1
check "drill-only item counts once"          "$(row clickops drill-only 'OPNsense/HAProxy/frontends/frontend\[fe-empty\]')" 1
check "remapped LAN prefix → env"            "$(row env value 'dnsmasq/hosts\[pve\]/ip')" 1
check "revision → accepted"                  "$(row accepted value revision/time)" 1
check "score = clickops rows"                "$(jq -r .score "$T/out.json")" 3
check "prom score line"                      "$(grep -c '^mgmt_opnsense_drill_realism_score 3$' "$T/out.prom")" 1
check "unused map line reported"             "$(grep -c 'matched nothing this run (stale?): 6$' "$T/report.md")" 1
check "report redacts item keys"             "$(grep -c 'fe-clicked' "$T/report.md" || true)" 0
check "detail file is 0600"                  "$(stat -c %a "$T/detail.tsv")" 600
[ "$fail" -eq 0 ] && echo "config-compare-test: all checks pass" || { echo "config-compare-test: FAILED"; exit 1; }
