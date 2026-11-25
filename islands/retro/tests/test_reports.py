"""The `reports` world's strict reader (unlabelled — proves no requirement row)."""

import json

import pytest

from retro_island import reports


def _copy(tmp_path, mutate):
    m = json.loads(reports.MANIFEST.read_text())
    mutate(m)
    p = tmp_path / "manifest.json"
    p.write_text(json.dumps(m))
    return p


def test_committed_manifest_loads_and_yields_the_text():
    (r,) = reports.load()
    assert r.path == "docs/agents/retros/2026-11-16-platform-r12-opus.md"
    assert "BEGIN-RETRO-FINDINGS" in r.text


def test_changed_sha256_raises(tmp_path):
    def flip(m):
        s = m[0]["sha256"]
        m[0]["sha256"] = ("0" if s[0] != "0" else "1") + s[1:]

    with pytest.raises(reports.ReportError, match="sha256"):
        reports.load(_copy(tmp_path, flip))


def test_missing_field_raises(tmp_path):
    with pytest.raises(reports.ReportError, match="missing"):
        reports.load(_copy(tmp_path, lambda m: m[0].pop("sha256")))


def test_added_field_raises(tmp_path):
    with pytest.raises(reports.ReportError, match="unknown"):
        reports.load(_copy(tmp_path, lambda m: m[0].update(extra="x")))
