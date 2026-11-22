"""Readers for the DECLARED records the access page points at — parsed, never restated.

- `tofu/github/*.tf` — the rulesets (a small HCL block reader: blocks, attributes, raw expressions);
- `agents/coordinator/island-intake-argo.yaml` — the sitting's ServiceAccount and token Secret;
- `agents/coordinator/*.yaml` — the ExternalSecret → GithubAccessToken chain that mints that Secret;
- `docs/github-apps.yaml` — the declared App permissions;
- `argocd/resources/agent-gateway/policy.json` — the gateway's `callers` map.

YAML goes through `yq` (the jail and the CI python carry no yaml module). Every reader is strict:
a record that is not where the page says it is raises, it never answers empty.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
RULESET_DIR = REPO / "tofu" / "github"
MANIFEST = REPO / "agents" / "coordinator" / "island-intake-argo.yaml"
MINT_DIR = REPO / "agents" / "coordinator"
APPS = REPO / "docs" / "github-apps.yaml"
POLICY = REPO / "argocd" / "resources" / "agent-gateway" / "policy.json"

LEVELS = {"read": 1, "write": 2}


# ── HCL: just enough to read blocks and attributes ─────────────────────────────────────────────


@dataclass
class Block:
    kind: str
    labels: list[str]
    attrs: dict[str, str] = field(default_factory=dict)
    blocks: list[Block] = field(default_factory=list)

    def children(self, kind: str) -> list[Block]:
        """Direct child blocks of `kind`, a `dynamic "<kind>"` block's `content` included."""
        out = [b for b in self.blocks if b.kind == kind]
        for d in self.blocks:
            if d.kind == "dynamic" and d.labels == [kind]:
                out.extend(d.children("content"))
        return out

    def one(self, kind: str) -> Block:
        found = self.children(kind)
        if len(found) != 1:
            raise ValueError(f"{self.kind} {self.labels}: expected one `{kind}` block, found {len(found)}")
        return found[0]


def _strip_comments(text: str) -> str:
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "#" or text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_LABEL = re.compile(r'"([^"]*)"')


def _expr_end(text: str, i: int) -> int:
    """End of an attribute expression starting at i: the first newline at bracket depth 0."""
    depth, in_str = 0, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c == "\n" and depth == 0:
            return i
        i += 1
    return i


def _parse_body(text: str, i: int, into: Block) -> int:
    while True:
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        if i >= len(text) or text[i] == "}":
            return i + 1
        m = _IDENT.match(text, i)
        if not m:
            raise ValueError(f"HCL: unexpected {text[i:i + 40]!r}")
        name, j = m.group(0), m.end()
        while j < len(text) and text[j] in " \t":
            j += 1
        if j < len(text) and text[j] == "=" and text[j + 1:j + 2] != "=":
            end = _expr_end(text, j + 1)
            into.attrs[name] = text[j + 1:end].strip()
            i = end
            continue
        labels = []
        while True:
            while j < len(text) and text[j] in " \t":
                j += 1
            lm = _LABEL.match(text, j)
            if not lm:
                break
            labels.append(lm.group(1))
            j = lm.end()
        if j >= len(text) or text[j] != "{":
            raise ValueError(f"HCL: `{name}` is neither an attribute nor a block")
        child = Block(name, labels)
        i = _parse_body(text, j + 1, child)
        into.blocks.append(child)


def hcl_file(path: Path) -> Block:
    root = Block("file", [str(path)])
    _parse_body(_strip_comments(path.read_text(encoding="utf-8")) + "\n}", 0, root)
    return root


def hcl_list(expr: str) -> list[str]:
    """A list of string literals, `["a", "b"]` — anything else raises."""
    expr = expr.strip()
    if not (expr.startswith("[") and expr.endswith("]")):
        raise ValueError(f"not a list literal: {expr!r}")
    inner = expr[1:-1].strip().rstrip(",")
    if not inner:
        return []
    items = [s.strip() for s in inner.split(",")]
    if not all(_LABEL.fullmatch(s) for s in items):
        raise ValueError(f"not a list of string literals: {expr!r}")
    return [s[1:-1] for s in items]


@dataclass
class Ruleset:
    resource: str
    name: str
    target: str
    include: list[str]
    block: Block


def rulesets() -> list[Ruleset]:
    """Every github_repository_ruleset / github_organization_ruleset under tofu/github/."""
    out = []
    for tf in sorted(RULESET_DIR.glob("*.tf")):
        for b in hcl_file(tf).children("resource"):
            if b.labels[0] not in ("github_repository_ruleset", "github_organization_ruleset"):
                continue
            name = b.attrs["name"].strip('"')
            target = b.attrs["target"].strip('"')
            include = []
            if target == "branch":
                include = hcl_list(b.one("conditions").one("ref_name").attrs["include"])
            out.append(Ruleset(f"{b.labels[0]}.{b.labels[1]}", name, target, include, b))
    if not out:
        raise RuntimeError(f"no rulesets read under {RULESET_DIR}")
    return out


def covers(include: list[str], ref: str, default_branch: str = "master") -> bool:
    """Does a ruleset `include` list cover `ref`? `~DEFAULT_BRANCH` = the default branch's ref;
    `**` crosses `/`, `*` does not (GitHub's ref-name fnmatch)."""
    for pat in include:
        if pat == "~ALL":
            return True
        if pat == "~DEFAULT_BRANCH":
            if ref == f"refs/heads/{default_branch}":
                return True
            continue
        rx = re.escape(pat).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(rx, ref):
            return True
    return False


def tf_variable_default(name: str) -> tuple[str, str]:
    """(default, description) of `variable "<name>"` in tofu/github/variables.tf."""
    for b in hcl_file(RULESET_DIR / "variables.tf").children("variable"):
        if b.labels == [name]:
            return b.attrs.get("default", "").strip('"'), b.attrs.get("description", "").strip('"')
    raise KeyError(f"no variable {name!r} in tofu/github/variables.tf")


def resolve_actor_id(expr: str) -> tuple[str, str]:
    """A bypass actor_id expression → (value, how it was resolved)."""
    expr = expr.strip()
    if re.fullmatch(r"\d+", expr):
        return expr, "literal"
    m = re.fullmatch(r"(?:tonumber\()?var\.([A-Za-z0-9_]+)\)?", expr)
    if not m:
        raise ValueError(f"unreadable actor_id expression {expr!r}")
    default, desc = tf_variable_default(m.group(1))
    return default, f"var.{m.group(1)} ({desc})"


# ── YAML / JSON records ────────────────────────────────────────────────────────────────────────


def yaml_docs(path: Path) -> list[dict]:
    out = subprocess.run(["yq", "ea", "-o=json", "-I=0", "[.]", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return [d for d in json.loads(out) if d]


def _walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from _walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v)


def sitting_workflow() -> dict:
    docs = [d for d in yaml_docs(MANIFEST)
            if d.get("kind") == "CronWorkflow" and d["metadata"]["name"] == "island-intake"]
    if len(docs) != 1:
        raise RuntimeError(f"{MANIFEST}: expected one CronWorkflow island-intake, found {len(docs)}")
    return docs[0]


def token_secret_refs(workflow: dict) -> set[str]:
    """The Secret names every `GH_TOKEN` env entry of the workflow reads."""
    refs = {n["valueFrom"]["secretKeyRef"]["name"] for n in _walk(workflow)
            if n.get("name") == "GH_TOKEN" and "valueFrom" in n}
    if not refs:
        raise RuntimeError("the island-intake workflow carries no GH_TOKEN env entry")
    return refs


@dataclass
class Identity:
    secret: str
    generator: str
    app_id: str
    slug: str
    minted: dict[str, str]
    declared: dict[str, str]
    repositories: list[str]

    def level(self, perm: str) -> int:
        """The token's effective level: what the mint requests, capped by what the App holds."""
        return min(LEVELS.get(self.minted.get(perm, ""), 0), LEVELS.get(self.declared.get(perm, ""), 0))


def declared_apps() -> dict[str, dict]:
    apps = json.loads(subprocess.run(["yq", "-o=json", str(APPS)], check=True,
                                     capture_output=True, text=True).stdout)["apps"]
    return {str(a["app_id"]): a for a in apps}


def identity_of(secret: str) -> Identity:
    """Follow Secret → ExternalSecret (target.name) → GithubAccessToken → the declared App."""
    docs = [d for f in sorted(MINT_DIR.glob("*.yaml")) for d in yaml_docs(f)]
    ext = [d for d in docs if d.get("kind") == "ExternalSecret"
           and d.get("spec", {}).get("target", {}).get("name") == secret]
    if len(ext) != 1:
        raise RuntimeError(f"expected one ExternalSecret writing Secret {secret!r}, found {len(ext)}")
    gens = [s["sourceRef"]["generatorRef"]["name"] for s in ext[0]["spec"].get("dataFrom", [])
            if s.get("sourceRef", {}).get("generatorRef", {}).get("kind") == "GithubAccessToken"]
    if len(gens) != 1:
        raise RuntimeError(f"ExternalSecret for {secret!r}: expected one GithubAccessToken source, found {gens}")
    gen = [d for d in docs if d.get("kind") == "GithubAccessToken" and d["metadata"]["name"] == gens[0]]
    if len(gen) != 1:
        raise RuntimeError(f"no GithubAccessToken {gens[0]!r} under {MINT_DIR}")
    spec = gen[0]["spec"]
    app = declared_apps().get(str(spec["appID"]))
    if app is None:
        raise RuntimeError(f"app id {spec['appID']} is not declared in docs/github-apps.yaml")
    return Identity(
        secret=secret,
        generator=gens[0],
        app_id=str(spec["appID"]),
        slug=app["slug"],
        minted=dict(spec["permissions"]),
        declared={k: v["level"] for k, v in app["permissions"].items()},
        repositories=list(spec["repositories"]),
    )


def gateway_callers() -> dict[str, dict]:
    return json.loads(POLICY.read_text(encoding="utf-8"))["callers"]
