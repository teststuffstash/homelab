#!/usr/bin/env python3
"""agentstack-rbac-lint — every kind the AgentStack Composition renders must have a crossplane
grant in argocd/resources/agentstack/rbac.yaml (its header rule), checked hermetically.

Crossplane v2 composes arbitrary kinds but its SA only holds RBAC for what it defines itself. A
composed kind with no grant does not fail loudly on the new resource — it parks the WHOLE claim
at Synced=False ("failed waiting for *unstructured.Unstructured Informer to sync") and nothing
new renders. Found five times by hand before this lint (pods/exec 2026-07-17, workflows,
endpoints 2026-07-26, ResourceQuota 2026-08-07, ClusterSecretStore 2026-09-14 — the last one is
the fixture this was written against: `git stash` the rbac.yaml row and this reds). A
Composition branch that has never executed carries no evidence its RBAC exists; this is the
evidence.

Scan (regex, not yaml-parse — the Composition is Go-templated): every `apiVersion:` + `kind:`
pair at the composed-document indent. Grant check: the rbac.yaml ClusterRole aggregated to
crossplane has a rule whose apiGroups contains the kind's group and whose resources contains
the kind's plural (lowercase(kind)+s, -y → -ies, or the bare lowercase kind) with at least the
verbs crossplane needs to observe + apply + garbage-collect.

Run: devbox run agentstack-rbac-lint   (pure-local: no network, no cluster — CI-safe)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
COMPOSITION = os.path.join(ROOT, "argocd", "resources", "agentstack", "composition.yaml")
RBAC = os.path.join(ROOT, "argocd", "resources", "agentstack", "rbac.yaml")
CLUSTERROLE = "crossplane-agentstack-composed"
NEED = {"get", "list", "watch", "create", "patch", "delete"}
# Kinds granted OUTSIDE rbac.yaml, each with the reason (verified `kubectl auth can-i` as the
# crossplane SA, 2026-09-14) — the only allow-list, kept short on purpose.
GRANTED_ELSEWHERE = {
    ("platform.teststuff.net", "AgentStack"): "the XR itself — crossplane core owns its own XRD kinds",
    ("tf.upbound.io", "Workspace"): "provider-terraform managed resource — the rbac-manager aggregates every installed provider's MRs to core",
}
INDENT = 12  # the composed documents inside the GoTemplate `inline.template` block


def composed_kinds(path):
    pairs, api = [], None
    pat_api = re.compile(r"^ {%d}apiVersion: (\S+)\s*$" % INDENT)
    pat_kind = re.compile(r"^ {%d}kind: (\S+)\s*$" % INDENT)
    with open(path) as f:
        for n, line in enumerate(f, 1):
            m = pat_api.match(line)
            if m:
                api = m.group(1)
                continue
            m = pat_kind.match(line)
            if m:
                if api is None:
                    sys.exit(f"{path}:{n}: kind without a preceding apiVersion at indent {INDENT}")
                group = api.split("/")[0] if "/" in api else ""
                pairs.append((group, m.group(1), n))
                api = None
    return pairs


def granted(path):
    out = subprocess.run(
        ["yq", "-o=json", "-I=0", f'select(.kind=="ClusterRole" and .metadata.name=="{CLUSTERROLE}") | .rules[]', path],
        capture_output=True, text=True, check=True).stdout
    import json
    grants = {}  # (group, resource) -> verbs
    for line in out.splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        for g in r.get("apiGroups", []):
            for res in r.get("resources", []):
                grants.setdefault((g, res), set()).update(r.get("verbs", []))
    return grants


def plurals(kind):
    k = kind.lower()
    yield k + "s"
    if k.endswith("y"):
        yield k[:-1] + "ies"
    yield k


def main():
    pairs = composed_kinds(COMPOSITION)
    if not pairs:
        sys.exit(f"agentstack-rbac-lint: FAIL — found no composed kinds in {COMPOSITION} (validated nothing)")
    grants = granted(RBAC)
    if not grants:
        sys.exit(f"agentstack-rbac-lint: FAIL — no rules read from ClusterRole {CLUSTERROLE} in {RBAC}")
    seen, bad = set(), []
    for group, kind, n in pairs:
        if (group, kind) in seen:
            continue
        seen.add((group, kind))
        if (group, kind) in GRANTED_ELSEWHERE:
            continue
        hit = next((p for p in plurals(kind) if (group, p) in grants), None)
        if hit is None:
            bad.append(f"  composition.yaml:{n}: {group or 'core'}/{kind} — NO rule in rbac.yaml grants it "
                       f"(add `{group}` × `{next(plurals(kind))}` with {sorted(NEED)})")
            continue
        missing = NEED - grants[(group, hit)]
        if missing:
            bad.append(f"  composition.yaml:{n}: {group or 'core'}/{kind} — rbac.yaml `{hit}` lacks verbs {sorted(missing)}")
    if bad:
        print("agentstack-rbac-lint: FAIL — a composed kind the crossplane SA cannot reconcile parks the WHOLE "
              "claim at Synced=False (rbac.yaml header):", file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        sys.exit(1)
    print(f"agentstack-rbac-lint: {len(seen)} composed kind(s) all granted in {CLUSTERROLE} "
          f"({len(GRANTED_ELSEWHERE)} granted elsewhere by allow-list)")


if __name__ == "__main__":
    main()
