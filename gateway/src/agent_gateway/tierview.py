"""The runtime tier derivation (GW-MODEL-TIERS §The derivation at a refresh, specs/endpoints/catalog.md).

The gateway derives the per-(rail, tier) model lists ITSELF, after every good refresh of either catalog
leg, from the evidence in its own store — the benched rows the OpenRouter leg keeps (`GET /catalog/openrouter`
`benchmarks`), the Go price (`GET /catalog/opencode` `pricing`), the openrouter models' selected endpoints
and rides, the manual benchmark rows when a file is mounted, and the policy's `tiers` block. The derivation
is `agent_gateway.tiers`' own (`build_snapshot` assembles the candidate rows, `derive` / `unscored` run the
rules) — nothing of it is rewritten here; only where its inputs come from and where its output goes.

SHADOW: nothing here is read by the admission. `GET /catalog/tiers` shows the derivation beside the lists
the admission walks (`equals_walked`). The last good derivation is kept in the store (`catalog_snapshots`,
source `tier-derivation`) and survives a restart; a refresh whose derivation cannot run keeps it.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from pathlib import Path

from .config import TIERS, Policy
from .store import Store
from .tiers import (
    AA_SOURCE,
    ManualError,
    build_snapshot,
    derive,
    parse_manual,
    undecided,
    unscored,
)

log = logging.getLogger("gateway.tierview")

SOURCE = "tier-derivation"  # the store's catalog_snapshots row
RAILS = ("anthropic", "opencode", "openrouter", "codex")


def _iso(ts: float | None) -> str | None:
    from .store import iso

    return iso(ts)


class TierDerivation:
    """Runs `derive` over the store's evidence, keeps the last good result, serves the view."""

    def __init__(self, policy: Policy, store: Store, go_view: Callable[[], dict], or_view: Callable[[], dict] | None,
                 clock, manual_path: str = ""):
        self.policy = policy
        self.store = store
        self.go_view = go_view
        self.or_view = or_view
        self.clock = clock
        self.manual_path = manual_path
        row = store.snapshot_load(SOURCE)
        self.derived_at: float | None = row[0] if row else None
        self.body: dict = row[1] if row else {}
        if row is not None and not isinstance(self.body.get("rails"), dict):
            log.error("tierview: the stored derivation is not this build's shape — ignored")
            self.derived_at, self.body = None, {}

    # -- inputs -----------------------------------------------------------------------------------
    def _manual(self) -> tuple[dict | None, str | None]:
        """(the manual file's document, why it was refused): no path or no file = no manual rows; a file
        `parse_manual` refuses is refused WHOLE — the derivation runs without it (⚖)."""
        if not self.manual_path:
            return None, None
        path = Path(self.manual_path)
        if not path.is_file():
            return None, None
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            parse_manual(doc)
        except (OSError, ValueError, ManualError) as e:  # a ManualError is a ValueError; json errors are too
            log.error("tierview: the manual benchmark file is refused (%s) — deriving without it", e)
            return None, str(e)
        return doc, None

    def _subscription(self, rail: str) -> list[str]:
        r = self.policy.rails.get(rail)
        ids: list[str] = []
        for tier in TIERS:
            for pid in (r.models.get(tier, ()) if r else ()):
                if pid not in ids:
                    ids.append(pid)
        return ids

    # -- the derivation ---------------------------------------------------------------------------
    def run(self) -> bool:
        """Derive now. False (the last good derivation stands) when it cannot run: no `tiers` block,
        no OpenRouter leg, no benched rows."""
        try:
            return self._run()
        except Exception:  # noqa: BLE001 — a derivation never takes a refresh down; the last good one stands
            log.exception("tierview: the derivation raised — keeping the last good one")
            return False

    def _run(self) -> bool:
        tiers = self.policy.tiers
        if tiers is None or self.or_view is None:
            return False
        orv = self.or_view()
        benched = orv.get("benchmarks") or {}
        if not benched:
            log.info("tierview: no benched rows — keeping the last good derivation")
            return False
        gov = self.go_view()
        go_held = (gov.get("sources") or {}).get("config", {}).get("fetched_at") is None
        manual, refused = self._manual()
        now = self.clock()
        capability = [[mid, AA_SOURCE, r.get("intelligence"), r.get("coding"), r.get("agentic"), None] for mid, r in benched.items()]
        snap = build_snapshot(
            capability=capability,
            go_catalog=gov if not go_held else {"models": {}, "sources": {"config": {"fetched_at": None}}},
            openrouter_catalog=orv,
            anthropic_aliases=self._subscription("anthropic"),
            codex_candidates=self._subscription("codex"),
            snapshot_at=_iso(now) or "", manual=manual)
        held = {r for r in RAILS if r not in self.policy.rails or (r == "opencode" and go_held)}
        snap["rails"] = {r: rows for r, rows in snap["rails"].items() if r not in held}
        lists = derive(snap, tiers)
        undec = undecided(snap, tiers)
        unsc = unscored(snap, tiers)
        prev = self.body.get("rails") or {}
        rails: dict[str, dict] = {}
        for rail, per_tier in lists.items():
            rows = snap["rails"][rail]
            out_tiers: dict[str, dict] = {}
            for tier in TIERS:
                ids = per_tier[tier]
                if ids:
                    out_tiers[tier] = {"list": ids, "evidence": {pid: self._evidence(rows[pid], tiers.score) for pid in ids}}
                else:  # undecided: the last derived list stands, never an empty one
                    out_tiers[tier] = (prev.get(rail, {}).get("tiers", {}).get(tier)) or {"list": [], "evidence": {}}
            rails[rail] = {"tiers": out_tiers, "undecided": undec.get(rail, []), "unscored": unsc.get(rail, [])}
        cap = snap["sources"]["capability"]
        self.body = {
            "stamps": {"benchmarks_as_of": (orv.get("sources") or {}).get("benchmarks", {}).get("as_of"),
                       "openrouter_fetched_at": orv.get("fetched_at"),
                       "opencode_fetched_at": None if go_held else snap["sources"]["go_catalog"]["fetched_at"]},
            "manual": {"used": (cap.get("manual") or {}).get("used", []), "retired": (cap.get("manual") or {}).get("retired", []),
                       "refused": refused},
            "rails": rails,
        }
        self.derived_at = now
        self.store.snapshot_save(SOURCE, now, self.body)
        log.info("tierview: derived — %s", "; ".join(f"{r}: " + "/".join(str(len(t['list'])) for t in v['tiers'].values())
                                                      for r, v in rails.items()))
        return True

    @staticmethod
    def _evidence(row: dict, axis: str) -> dict:
        rides = row.get("rides") or {}
        return {"aa_id": row.get("aa_id"), "score": row.get(axis), "price": row.get("out_price"), "basis": row.get("price_basis"),
                "score_source": row.get("score_source", "feed"),
                "rides": {"clean": rides.get("clean", 0), "judged": rides.get("judged", 0), "prior": rides.get("prior", 1.0)}}

    # -- the view ---------------------------------------------------------------------------------
    def view(self) -> dict:
        """`GET /catalog/tiers`: the derivation beside the lists the admission walks. No derivation =
        `derived_at` null and no rails, never an error."""
        stamps = self.body.get("stamps") or {"benchmarks_as_of": None, "openrouter_fetched_at": None, "opencode_fetched_at": None}
        manual = self.body.get("manual") or {"used": [], "retired": [], "refused": None}
        rails: dict[str, dict] = {}
        for rail, v in (self.body.get("rails") or {}).items():
            policy_rail = self.policy.rails.get(rail)
            tiers = {}
            for tier in TIERS:
                t = (v.get("tiers") or {}).get(tier) or {"list": [], "evidence": {}}
                walked = list(policy_rail.models.get(tier, ())) if policy_rail else None
                tiers[tier] = {"list": t["list"], "evidence": t["evidence"], "equals_walked": walked is not None and walked == t["list"]}
            rails[rail] = {"tiers": tiers, "undecided": v.get("undecided", []), "unscored": v.get("unscored", [])}
        return {"derived_at": _iso(self.derived_at), **stamps, "manual": manual, "rails": rails}
