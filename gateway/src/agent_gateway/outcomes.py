"""A session's outcome and the strike store (GW-SESSIONS-OUTCOME, specs/endpoints/sessions.md).

The principle: the gateway owns what it sees first-hand; the consumer classifies its own output.
Both write into ONE store in ONE vocabulary — `OUTCOME_CLASSES` below, pinned to the schema's enum
(`sessions.schema.json` `outcome.class`) by a test row, so no consumer keeps a drifting copy (the
old router's `STRIKE_CLASSES` rule, docs/agents/model-routing.md §The strike ladder).

- The consumer reports `POST /sessions/{id}/outcome {class, subclass?, evidence?}` (the admitting
  caller, or a judge whose `callers` entry says `outcome: any`).
- The gateway writes its own transport classes from the data plane (`transport()`): an upstream
  credential failure, a 5xx / unreachable upstream, a timeout, a refusal, an incomplete stream.
- A strike is keyed (stack, task, rail, model, provider) and scoped: `cell` (serving-shaped —
  excludes that (rail, model) for the task) or `model` (excludes the model on every rail for the
  task). At most one strike per (session, class, source).
- Rounds ≠ strikes: a logic failure (CHANGES_REQUESTED, CI red) is no class here — the consumer's
  round counter owns it.
- A `clean` outcome refutes the task's counted strikes on the same cell (cell scope) and the same
  model (model scope); a bare 2xx refutes nothing.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from .logging import redact
from .store import Session, Store

log = logging.getLogger("gateway.outcomes")

# class -> scope ("cell" | "model" | None for `clean`). One home: sessions.md §The vocabulary.
OUTCOME_CLASSES: dict[str, str | None] = {
    "clean": None,
    # the old router's set (router.py STRIKE_CLASSES; SERVING_CLASSES → cell)
    "harness-death": "model",
    "auth-storm": "cell",
    "timeout": "cell",
    "provider-5xx": "cell",
    "no-pr": "model",
    "unknown": "model",
    "turn-cap": "model",
    "tool-loop": "cell",
    # the review-shaped classes the 2026-10-17 free-model experiment proved
    "no-verdict": "model",
    "wrong-verdict": "model",
    "invented-findings": "model",
    "repetition": "model",
    "harness-gave-up": "cell",
    # the gateway's own transport classes (PR 1's facts) that have no old-router twin
    "stream-incomplete": "cell",
    "refused": "cell",
}
JUDGE_ONLY = frozenset({"wrong-verdict"})  # a verdict's correctness is not the reviewer's own call
SOURCES = ("outcome", "gateway")
EVIDENCE_MAX = 4096  # bytes of JSON


class OutcomeRefused(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass(frozen=True)
class Outcome:
    klass: str
    subclass: str | None
    evidence: object
    reporter: str | None
    at: float


def parse_outcome(body: object) -> tuple[str, str | None, object]:
    if not isinstance(body, dict):
        raise OutcomeRefused(400, "malformed-body", "body must be a JSON object {class, subclass?, evidence?}")
    extra = set(body) - {"class", "subclass", "evidence"}
    if extra:
        raise OutcomeRefused(400, "malformed-body", f"outcome carries unknown keys: {', '.join(sorted(extra))}")
    klass = body.get("class")
    if not isinstance(klass, str) or not klass:
        raise OutcomeRefused(400, "malformed-body", "class is required (a vocabulary member)")
    if klass not in OUTCOME_CLASSES:
        raise OutcomeRefused(400, "outcome-class-unknown",
                             f"{klass!r} is not an outcome class — a logic failure (CHANGES_REQUESTED, CI red) is a ROUND, "
                             "counted by the consumer, never an outcome")
    sub = body.get("subclass")
    if sub is not None and (not isinstance(sub, str) or len(sub) > 128):
        raise OutcomeRefused(400, "malformed-body", "subclass, when present, is a string of at most 128 characters")
    evidence = body.get("evidence")
    if evidence is not None:
        raw = json.dumps(evidence, separators=(",", ":"))
        if len(raw.encode()) > EVIDENCE_MAX:
            raise OutcomeRefused(400, "malformed-body", f"evidence is at most {EVIDENCE_MAX} bytes of JSON")
        if _credential_shaped(evidence):
            raise OutcomeRefused(400, "outcome-evidence-refused", "evidence carries a credential-shaped value")
    if sub is not None and _credential_shaped(sub):
        raise OutcomeRefused(400, "outcome-evidence-refused", "subclass carries a credential-shaped value")
    return klass, sub, evidence


def _credential_shaped(v: object) -> bool:
    if isinstance(v, str):
        return redact(v) != v  # the GW-REDACT patterns, JWTs included
    if isinstance(v, dict):
        return any(_credential_shaped(x) for x in v.values()) or any(_credential_shaped(k) for k in v)
    if isinstance(v, list):
        return any(_credential_shaped(x) for x in v)
    return False


class Outcomes:
    def __init__(self, store: Store, metrics, window_s: int, clock):
        self.store = store
        self.metrics = metrics
        self.window_s = window_s
        self.clock = clock

    def report(self, row: Session, klass: str, sub: str | None, evidence: object, reporter: str | None,
               judge: bool) -> dict:
        """The consumer's outcome. Raises OutcomeRefused (403 judge-only, 409 window / conflict)."""
        now = self.clock()
        if klass in JUDGE_ONLY and not judge:
            raise OutcomeRefused(403, "outcome-judge-only", f"{klass} is a judge's call — a caller with callers.<sa>.outcome = any")
        end = row.released_at if row.released_at is not None and row.released_at < row.expires_at else row.expires_at
        if row.state(now) != "active" and now > end + self.window_s:
            raise OutcomeRefused(409, "outcome-window-closed",
                                 f"the session ended at {end:.0f}; outcomes are accepted until {self.window_s} s after its end")
        prev = self.store.outcome_by(row.id, reporter)
        if prev is not None:
            if prev["class"] == klass and prev["subclass"] == sub:
                return self._answer(row, prev, None, 0, replay=True)
            raise OutcomeRefused(409, "outcome-conflict", f"this caller already reported {prev['class']} for session {row.id}")
        rec = self.store.add_outcome(row.id, klass, sub, None if evidence is None else json.dumps(evidence, separators=(",", ":")),
                                     reporter, now)
        strike = None
        refuted = 0
        scope = OUTCOME_CLASSES[klass]
        if scope is None:
            refuted = self.store.refute_strikes(row.stack, row.task, row.rail, row.model, now,
                                                providers=self.store.session_providers(row.id))
            log.info("outcome: session=%s clean — refuted %d strike(s) on task %s", row.id, refuted, row.task)
        else:
            # A consumer's cell-scoped class lands on the provider(s) the ride rode — one strike per cell
            # it touched; a ride that rode none (unpinned, no attribution) strikes the model's own cell.
            rode = sorted(self.store.session_providers(row.id)) if scope == "cell" else []
            strike = self._strike(row, klass, scope, "outcome", now, rode[0] if rode else "")
            for p in rode[1:]:
                self._strike(row, klass, scope, "outcome", now, p)
        log.info("outcome: session=%s class=%s subclass=%s reporter=%s", row.id, klass, sub or "-", reporter or "(unauthenticated)")
        return self._answer(row, rec, strike, refuted)

    def transport(self, row: Session, klass: str, provider: str = "") -> None:
        """The gateway's own transport fact as a strike on the session's cell (at most one per class
        and provider); `provider` = the serving provider's slug on the openrouter rail ('' = unpinned,
        the model's own cell — GW-RAIL-OPENROUTER §Attribution)."""
        scope = OUTCOME_CLASSES[klass]
        assert scope is not None
        self._strike(row, klass, scope, "gateway", self.clock(), provider)

    def _strike(self, row: Session, klass: str, scope: str, source: str, now: float, provider: str = "") -> dict | None:
        if self.store.add_strike(row.stack, row.task, row.rail, row.model, provider, klass, scope, source, row.id, now):
            self.metrics.strike(klass, source)
            log.warning("strike: %s/%s %s on %s %s%s (scope %s, source %s, session %s)",
                        row.stack, row.task, klass, row.rail, row.model, f" @{provider}" if provider else "",
                        scope, source, row.id)
        return {"class": klass, "scope": scope}  # the wire's strike; the provider is the store row's (GET shows none)

    @staticmethod
    def _answer(row: Session, rec: dict, strike: dict | None, refuted: int, replay: bool = False) -> dict:
        return {"id": row.id, "outcome": public_outcome(rec), "strike": strike, "refuted": refuted, "replay": replay}


def public_outcome(rec: dict | None) -> dict | None:
    if rec is None:
        return None
    from .store import iso  # local: store imports nothing from here

    return {"class": rec["class"], "subclass": rec["subclass"],
            "evidence": json.loads(rec["evidence"]) if rec["evidence"] else None,
            "reporter": rec["reporter"], "at": iso(rec["at"])}
