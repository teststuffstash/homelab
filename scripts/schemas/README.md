# Vendored CRD schemas for manifest-lint (homelab#1200)

`scripts/manifest-lint.sh` runs `kubeconform` with `-schema-location
'scripts/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` ahead of
`-schema-location default` — kubeconform's own layout for a local CRD schema catalog (kind
lowercased). This directory holds the CRDs kubeconform has no upstream schema for, generated
**offline from the live cluster's CRD**, not fetched from the network — CI must never dial out for
a schema (the uncached-schema-fetch flake class, FU-197, PR#1099); a vendored file also survives
the cluster being down.

## Why the cluster and not a schema registry

A public catalog exists (`datreeio/CRDs-catalog` carries `cilium.io` schemas), but it is a
third-party snapshot of SOME Cilium version, fetched over the WAN at lint time — both properties
this gate must not have (offline CI, FU-197; version parity with the running CNI). The CRD itself,
already `openAPIV3Schema`-shaped, IS the schema, and the cluster's own CRD is authoritative for the
version actually running; vendoring it pins exactly that.

## Files

| File | CRD | Cilium version at generation |
|---|---|---|
| `cilium.io/ciliumnetworkpolicy_v2.json` | `ciliumnetworkpolicies.cilium.io` | 1.19.1 |
| `cilium.io/ciliumclusterwidenetworkpolicy_v2.json` | `ciliumclusterwidenetworkpolicies.cilium.io` | 1.19.1 |

## How they were generated

```bash
devbox run -- kubectl --kubeconfig tofu/kubeconfig get crd ciliumnetworkpolicies.cilium.io -o json \
  | python3 -c '
import json, sys
crd = json.load(sys.stdin)
v2 = next(v for v in crd["spec"]["versions"] if v["name"] == "v2")
schema = v2["schema"]["openAPIV3Schema"]
out = {"$schema": "http://json-schema.org/draft-07/schema#", **schema}
json.dump(out, sys.stdout, indent=2)
' > scripts/schemas/cilium.io/ciliumnetworkpolicy_v2.json
```

Same for `ciliumclusterwidenetworkpolicies.cilium.io` → `ciliumclusterwidenetworkpolicy_v2.json`.
kubeconform accepts the CRD's `openAPIV3Schema` object directly; the `$schema` draft-07 pointer was
added defensively (kubeconform's own bundled schemas carry one) but is not load-bearing — the
vendored files validate identically with or without it.

## Re-generation trigger

**A stale vendored schema is the FU-108 "probe that returns cleanly" class**: kubeconform will
happily validate a CNP against an outdated schema and report green while the live CRD has since
grown a field the schema doesn't know (kubeconform's `-strict` then wrongly REJECTS a valid field)
or dropped a validation the schema still enforces (silently permissive). **Re-run the command above
whenever `tofu/variables.tf`'s `cilium_version` bumps** — Cilium's CRD schema changes between minor
versions far more often than the API version (`v2`) does. There is no automation for this yet
(FU-197's offline-only constraint means it cannot run in CI against the live cluster); it is a
manual step in the Cilium-bump recipe.
