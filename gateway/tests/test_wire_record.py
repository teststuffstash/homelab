"""GW-WIRE-RECORD — the gateway keeps each vendor read's latest answer (specs/endpoints/wire.md §The recorder).

World: policy-codex · the fake vendor (tests/_catalog_world.py: `catalog-*`, `config-*`) for the Go
catalog's reads, the codex usage fake (tests/fixtures/codex-usage-observed.json) for the account poll.
T0 = the test clock (2027-01-15T08:00:00Z). The tables are the spec's, verbatim; the header is the
parameter list (`class` is `source_class` here — a column cannot be a Python keyword).
"""

from __future__ import annotations

import hashlib
import json
import logging

import httpx
import pytest
from starlette.responses import JSONResponse

from agent_gateway.codex import CodexBackend, CodexRail
from agent_gateway.codex_usage import UsagePoll
from agent_gateway.config import Policy
from agent_gateway.metrics import Metrics
from agent_gateway.wire import WireDeclarationError, parse_declarations

from ._catalog_rows import T0, at_offset
from ._catalog_world import catalog_doc
from ._codex_rows import row, verdicts
from ._codex_world import CODEX_BASE, CODEX_POLICY
from .conftest import GO_KEY, attach_json, given, quiet, rule, when, world
from .test_codex_usage_poll import usage_doc

pytestmark = rule("GW-WIRE-RECORD")

CODEX_USAGE_URL = "https://codex.test/backend-api/wham/usage"


def _bytes_of(behaviour: str) -> bytes:
    """What the fake vendor's catalog read answers for `behaviour`, byte for byte."""
    return JSONResponse(catalog_doc(behaviour)).body


async def _read(cworld, vendor, vendor_transport, clock, reads: str):
    """`catalog-ok at T0, then catalog-503 at T0 + 60 s` → the config source refreshed once per step."""
    app = cworld.build()
    steps = [s.strip() for s in reads.replace("then ", "").split(",")]
    for step in steps:
        behaviour, _, at = step.partition(" at ")
        clock.t = T0 + (at_offset(at) if at else 0)
        vendor.catalog = behaviour if behaviour.startswith("catalog-") else "catalog-ok"
        if behaviour.endswith("-down"):
            vendor_transport.down.add("catalog")
        with quiet():
            await app.state.catalog.refresh_source("config")
    return app


def _stored(app, source: str) -> dict:
    return app.state.store.wire_get(source) or {}


def _strings_only_as_len(doc) -> bool:
    """Independent of the recorder's own walk: no str value anywhere in the stored structure."""
    if isinstance(doc, dict):
        if set(doc) == {"len"}:
            return isinstance(doc["len"], int)
        return all(_strings_only_as_len(v) for v in doc.values())
    if isinstance(doc, list):
        return all(_strings_only_as_len(v) for v in doc)
    return not isinstance(doc, str)


def _leaves(doc, path="", raw_strings=False) -> dict:
    """Key path -> leaf: numbers/booleans/null as themselves, a string as its length (`{"len": n}` stored, or the raw string's length)."""
    if isinstance(doc, dict) and set(doc) == {"len"} and not raw_strings:
        return {path: f"len={doc['len']}"}
    if isinstance(doc, dict):
        return {k: v for key, val in doc.items() for k, v in _leaves(val, f"{path}/{key}", raw_strings).items()}
    if isinstance(doc, list):
        return {k: v for i, val in enumerate(doc) for k, v in _leaves(val, f"{path}[{i}]", raw_strings).items()}
    if isinstance(doc, str):
        return {path: f"len={len(doc)}"}
    return {path: doc}


# ── A read's answer is kept ──────────────────────────────────────────────────────────────────
NOCRED = "none (no credential, no account header)"
KEPT_ROWS = [
    pytest.param("go-models-dev", "catalog-ok at T0", NOCRED, "public", "the fake's bytes, byte-identical", "the bytes' sha256", "T0",
                 id="a public read's bytes are kept verbatim"),
    pytest.param("go-models-dev", "catalog-ok at T0, then catalog-trimmed at T0 + 21600 s", NOCRED, "public", "the later bytes", "the later bytes' sha256",
                 "T0 + 21600 s", id="a later answer replaces it"),
    pytest.param("go-models-dev", "catalog-malformed at T0", NOCRED, "public", "the malformed bytes", "their sha256", "T0",
                 id="a shape the parser refuses is still recorded ⚖"),
    pytest.param("codex-usage", "the observed usage shape at T0", "the codex bearer and account header", "account", "every key, number and boolean; every string `{\"len\": n}`",
                 "the raw bytes' sha256", "T0", id="an account read keeps its structure and no string value ⚖"),
]


@pytest.mark.parametrize(("source", "read", "credential_sent", "expected_source_class", "expected_stored", "expected_sha256", "expected_fetched_at"), KEPT_ROWS,
                         ids=[p.id for p in KEPT_ROWS])
async def test_a_reads_answer_is_kept(cworld, vendor, vendor_transport, clock, codex_store, exchange, source, read, credential_sent, expected_source_class, expected_stored,
                                      expected_sha256, expected_fetched_at):
    world("policy-codex", upstream=read)
    row(source=source, read=read, credential_sent=credential_sent)
    if source == "codex-usage":
        app = cworld.build()
        raw = json.dumps(usage_doc(clock)).encode()
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda r: httpx.Response(200, headers={"content-type": "application/json"}, content=raw)))
        rail = CodexRail(Policy.load(CODEX_POLICY).rails["codex"], clock, CodexBackend(codex_store, exchange), CODEX_BASE)
        poll = UsagePoll(rail, client, CODEX_USAGE_URL, Metrics(["platform"]), clock, app.state.wire)
        with when("the codex usage poll reads the account's usage at T0"):
            await poll.poll()
        await client.aclose()
        want_bytes = None
    else:
        with when(f"the config source refreshes: {read}"):
            app = await _read(cworld, vendor, vendor_transport, clock, read)
        last = read.split("then ")[-1].split(" at ")[0]
        want_bytes = _bytes_of(last.strip())
    rec = _stored(app, source)
    if want_bytes is not None:
        got_view = {"body_sha256": hashlib.sha256(rec["body"]).hexdigest(), "bytes": len(rec["body"])}
        want_view = {"body_sha256": hashlib.sha256(want_bytes).hexdigest(), "bytes": len(want_bytes)}
        want_sha = hashlib.sha256(want_bytes).hexdigest()
    else:
        doc = json.loads(rec["body"])
        assert _strings_only_as_len(doc) and b"DUMMY-SECRET" not in rec["body"]
        got_view = _leaves(doc)
        want_view = _leaves(usage_doc(clock), raw_strings=True)
        want_sha = hashlib.sha256(raw).hexdigest()
    attach_json("the stored record", {k: v for k, v in rec.items() if k != "body"})
    attach_json("compared: stored key paths and leaves", {"stored": got_view, "expected": want_view})
    verdicts(source_class=(rec["class"], expected_source_class), stored=(got_view, want_view), sha256=(rec["sha256"], want_sha),
             fetched_at=(rec["fetched_at"], T0 + at_offset(expected_fetched_at)))


# ── A failed read, a bound, a restart ────────────────────────────────────────────────────────
FAIL_ROWS = [
    pytest.param("go-models-dev", "catalog-ok at T0, then catalog-503 at T0 + 60 s", 1048576, "T0's bytes", "status 503 at the later time", "true",
                 id="a failed read keeps the last good answer and records the failure beside it ⚖"),
    pytest.param("go-models-dev", "catalog-down at T0", 1048576, "none", "unreachable", "true", id="an unreachable vendor records no bytes"),
    pytest.param("go-models-dev", "catalog-ok at T0", 600, "the first 600 bytes", "none", "false", id="an answer over the bound is cut and says so ⚖"),
    pytest.param("go-models-dev", "catalog-ok at T0, restart at T0 + 3600 s", 1048576, "T0's bytes", "none", "true",
                 id="a record survives a restart"),
]


@pytest.mark.parametrize(("source", "read", "max_bytes", "expected_last_ok", "expected_last_error", "expected_complete"), FAIL_ROWS,
                         ids=[p.id for p in FAIL_ROWS])
async def test_a_failed_read_a_bound_a_restart(cworld, vendor, vendor_transport, clock, source, read, max_bytes, expected_last_ok,
                                               expected_last_error, expected_complete):
    world("policy-codex", upstream=read)
    row(source=source, read=read, max_bytes=max_bytes)
    restart = ", restart at" in read
    reads = read.split(", restart")[0]
    with when(f"the config source refreshes: {reads} (max_bytes {max_bytes})"):
        first = cworld.build()
        first.state.wire.max_bytes = max_bytes
        steps = [s.strip() for s in reads.replace("then ", "").split(",")]
        for step in steps:
            behaviour, _, at = step.partition(" at ")
            clock.t = T0 + at_offset(at)
            vendor.catalog = behaviour
            if behaviour.endswith("-down"):
                vendor_transport.down.add("catalog")
            with quiet():
                await first.state.catalog.refresh_source("config")
        app = first
        if restart:
            first.state.store.close()
            clock.t = T0 + 3600
            app = cworld.build()
    rec = _stored(app, source)
    ok_bytes = _bytes_of("catalog-ok")
    want = {"T0's bytes": ok_bytes, "the first 600 bytes": ok_bytes[:600], "none": None}[expected_last_ok]
    got_ok = rec.get("body")
    want_error = {"status 503 at the later time": ("status 503", T0 + 60), "unreachable": ("unreachable", T0), "none": (None, None)}[expected_last_error]
    attach_json("the stored record", {k: v for k, v in rec.items() if k != "body"})
    verdicts(last_ok=(got_ok, want), last_error=((rec["last_error"], rec["last_error_at"]), want_error),
             complete=(str(bool(rec["complete"]) if rec["fetched_at"] is not None else True).lower(), expected_complete))


# ── The credential never lands in a record ──────────────────────────────────────────────────
KEY_ROWS = [
    pytest.param("go-console-config", "config-401-echo", "the Go key as a bearer", "account", "status 401", 0, 0,
                 id="a vendor answer that echoes the key is withheld ⚖"),
    pytest.param("go-console-config", "config-200-echo", "the Go key as a bearer", "account", "withheld", 0, 0,
                 id="a good answer that echoes the key is withheld whole ⚖"),
    pytest.param("go-console-config", "config-ok", "the Go key as a bearer", "account", "none", 0, 0,
                 id="a read that carried a credential is never class public ⚖"),
]


@pytest.mark.parametrize(("source", "read", "credential_sent", "expected_source_class", "expected_last_error",
                          "expected_record_fields_with_key", "expected_log_lines_with_key"), KEY_ROWS, ids=[p.id for p in KEY_ROWS])
async def test_the_credential_never_lands_in_a_record(cworld, vendor, caplog, source, read, credential_sent, expected_source_class,
                                                      expected_last_error, expected_record_fields_with_key, expected_log_lines_with_key):
    world("policy-codex", upstream=read)
    row(source=source, read=read, credential_sent=credential_sent)
    caplog.set_level(logging.DEBUG)
    app = cworld.build()
    with given(f"the console answers {read}"):
        vendor.config = read
    with when(f"the config source refreshes (the config read carries {credential_sent})"):
        with quiet():
            await app.state.catalog.refresh_source("config")
    rec = _stored(app, source)
    key = GO_KEY.encode()
    in_record = sum(1 for v in rec.values() if isinstance(v, (str, bytes)) and key in (v if isinstance(v, bytes) else v.encode()))
    lines = sum(1 for r in caplog.records if GO_KEY in r.getMessage())
    got_error = rec.get("last_error")
    verdicts(source_class=(rec.get("class"), expected_source_class), last_error=("none" if got_error is None else got_error, expected_last_error),
             record_fields_with_key=(in_record, expected_record_fields_with_key), log_lines_with_key=(lines, expected_log_lines_with_key))


# ── The account class's allowlist (GW-WIRE-PROBE's declarations file) ────────────────────────
async def _probe_answer(tmp_path, settings, secrets, store, clock, codex_store, exchange, keep_keys, answer: str):
    import dataclasses

    from agent_gateway.app import create_app
    from agent_gateway.codex import CodexBackend

    from .test_wire_probe import WIRE_CODEX
    doc = json.loads(WIRE_CODEX)
    doc["keep_keys"] = {"codex-models": keep_keys}
    f = tmp_path / "wire.json"
    f.write_text(json.dumps(doc), encoding="utf-8")
    client = httpx.AsyncClient(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, headers={"content-type": "application/json"}, content=answer.encode())))
    s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE}, wire_path=str(f))
    app = create_app(s, policy=Policy.load(CODEX_POLICY), source=secrets, store=store, client=client, clock=clock,
                     codex_backend=CodexBackend(codex_store, exchange))
    attach_json("declarations", doc)
    await app.state.wire_probe.tick()
    await client.aclose()
    return app


SLUG = '`{"slug": "fixture-model", "note": "hello"}`'
UNSET = "`GATEWAY_WIRE` unset, source `codex-usage`"
# the stored? cell -> the document the record must hold
STORED = {
    '`"slug": "fixture-model"`, `"note": {"len": 5}`': {"slug": "fixture-model", "note": {"len": 5}},
    "both strings as lengths": {"slug": {"len": 13}, "note": {"len": 5}},
    '`{"a": {"slug": "x"}, "slug": ["p", 3], "other": [{"len": 1}]}`': {"a": {"slug": "x"}, "slug": ["p", 3], "other": [{"len": 1}]},
    "the value as its length": {"slug": {"len": 25}},
}
ALLOW_ROWS = [
    pytest.param("`[slug]`", SLUG, '`"slug": "fixture-model"`, `"note": {"len": 5}`', "loads", id="an allowlisted key keeps its string, every other string its length ⚖"),
    pytest.param("`[]`", SLUG, "both strings as lengths", "loads", id="no allowlist keeps no string"),
    pytest.param("`[slug]`", '`{"a": {"slug": "x"}, "slug": ["p", 3], "other": ["q"]}`',
                 '`{"a": {"slug": "x"}, "slug": ["p", 3], "other": [{"len": 1}]}`', "loads", id="an allowlisted key is kept at any depth and in a list"),
    pytest.param(UNSET, "the observed usage shape", "every string as its length", "—", id="no declarations file keeps no string ⚖"),
    pytest.param("`[slug]`", '`{"slug": "sk-ant-oat-FAKE…"}`', "the value as its length", "loads",
                 id="an allowlisted value that matches a credential pattern is still withheld ⚖"),
]


@pytest.mark.parametrize(("keep_keys", "answer", "expected_stored", "expected_load"), ALLOW_ROWS, ids=[p.id for p in ALLOW_ROWS])
async def test_the_account_classs_allowlist(tmp_path, settings, secrets, store, clock, codex_store, exchange, keep_keys, answer, expected_stored, expected_load):
    world("policy-codex", upstream="wire-codex")
    row(keep_keys=keep_keys, answer=answer)
    if keep_keys == UNSET:
        from agent_gateway.app import create_app
        app = create_app(settings, policy=Policy.load(CODEX_POLICY), source=secrets, store=store, clock=clock)
        raw = json.dumps(usage_doc(clock)).encode()
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda r: httpx.Response(200, headers={"content-type": "application/json"}, content=raw)))
        rail = CodexRail(Policy.load(CODEX_POLICY).rails["codex"], clock, CodexBackend(codex_store, exchange), CODEX_BASE)
        with when("the codex usage poll reads the account's usage with no declarations file"):
            await UsagePoll(rail, client, CODEX_USAGE_URL, Metrics(["platform"]), clock, app.state.wire).poll()
        await client.aclose()
        stored = _strings_only_as_len(json.loads(app.state.store.wire_get("codex-usage")["body"]))
        verdicts(stored=("every string as its length" if stored else "a string kept", expected_stored), load=("—", expected_load))
        return
    keys = [k.strip() for k in keep_keys.strip("`[]").split(",") if k.strip()]
    text = answer.strip("`").replace("…", "0123456789")
    with when(f"the codex-models probe reads an answer with keep_keys {keys}"):
        app = await _probe_answer(tmp_path, settings, secrets, store, clock, codex_store, exchange, keys, text)
    stored = json.loads(app.state.store.wire_get("codex-models")["body"])
    attach_json("the stored record", stored)
    verdicts(stored=(stored, STORED[expected_stored]), load=("loads", expected_load))


# ── What an allowlist may not name ───────────────────────────────────────────────────────────
NAME_ROWS = [
    pytest.param("`[email]`", "refused, naming email", id="an identity key can never be allowlisted ⚖"),
    pytest.param("`[account_id]`", "refused, naming account_id", id="an account id is an identity key"),
    pytest.param("`[user_id]`", "refused, naming user_id", id="a user id is an identity key"),
    pytest.param("`[access_token]`", "refused, naming access_token", id="a token-named key is never allowlisted"),
    pytest.param("`[Set-Cookie]`", "refused, naming Set-Cookie", id="a cookie-named key is never allowlisted"),
    pytest.param("`[client_secret]`", "refused, naming client_secret", id="a secret-named key is never allowlisted"),
]


@pytest.mark.parametrize(("keep_keys", "expected_load"), NAME_ROWS, ids=[p.id for p in NAME_ROWS])
def test_what_an_allowlist_may_not_name(keep_keys, expected_load):
    world("policy-codex", upstream="wire-codex")
    row(keep_keys=keep_keys)
    key = keep_keys.strip("`[]")
    with when(f"a declarations file allowlists {key}"):
        try:
            parse_declarations({"keep_keys": {"codex-usage": [key]}}, ["codex"])
            got = "loads"
        except WireDeclarationError as e:
            got = f"refused, naming {key}" if key in str(e) else "refused"
    verdicts(load=(got, expected_load))
