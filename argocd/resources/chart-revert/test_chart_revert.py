#!/usr/bin/env python3
"""chart-revert unit tests — the predicate, the payload parsing, the ledger decision, and the
whole handle_alert walk against a FAKE runner (no gh, no git, no network).

  devbox run chart-revert-self-test
  (= python3 -m unittest discover -s argocd/resources/chart-revert -p 'test_*.py')

The #2254 fixture below is the REAL squash-commit patch of the argo-workflows 1.1.1 → 2.0.8 bump
(gh api repos/teststuffstash/homelab/commits/4bb522d3): the pin comment was rewritten too, which is
exactly what the predicate must allow and what a `uses:`-shaped grammar would have refused."""

import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chart_revert as cr  # noqa: E402

TARGET_FILE = "argocd/platform/argo-workflows.yaml"
SHA = "4bb522d3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PATCH_2254 = (
    "@@ -18,11 +18,13 @@ spec:\n   source:\n     repoURL: https://argoproj.github.io/argo-helm\n"
    "     chart: argo-workflows\n"
    "-    # app v4.0.8 (the last 1.0.x chart; 2.0.x = app v4.1). v4.0.8 carries the two upstream fixes the\n"
    "-    # 2026-09-20 apiserver-restart storm and the 2026-08-31 lock-plane wedge asked for: configmap\n"
    "-    targetRevision: 1.1.1\n"
    "+    # app v4.1.4 (chart 2.0.8). v4.1.x carries the two upstream fixes the 2026-09-20\n"
    "+    # apiserver-restart storm and the 2026-08-31 lock-plane wedge asked for: configmap watchers\n"
    "+    # ahead of v4.1.0-rc1, so v4.1.4 carries them directly — retained, not reverted.\n"
    "+    targetRevision: 2.0.8\n"
    "     helm:\n       valuesObject:\n         crds:"
)
COMMIT_2254 = [{"filename": TARGET_FILE, "status": "modified", "patch": PATCH_2254}]
NOW = datetime(2026, 10, 5, 18, 0, tzinfo=timezone.utc)


def alert(name="ArgoControllerSilent", status="firing", **labels):
    labels.setdefault("alertname", name)
    return {"status": status, "labels": labels, "annotations": {}, "startsAt": "2026-10-05T17:40:00Z"}


def pr(number=2254, merged="2026-10-05T17:30:00Z", head="renovate/argo-workflows-2.x", files=(TARGET_FILE,), oid=SHA):
    return {"number": number, "title": f"chore(deps): update helm release argo-workflows to v2 (#{number})",
            "headRefName": head, "mergedAt": merged, "mergeCommit": {"oid": oid},
            "files": [{"path": f} for f in files], "state": "MERGED"}


class SelectAlerts(unittest.TestCase):
    def test_firing_target_only(self):
        payload = {"alerts": [alert(), alert(status="resolved"), alert(name="Watchdog"), "junk"]}
        self.assertEqual(len(cr.select_alerts(payload)), 1)

    def test_malformed(self):
        for bad in ([], {"alerts": "x"}, {"nope": 1}, None):
            with self.assertRaises(ValueError):
                cr.select_alerts(bad)


class DrillTarget(unittest.TestCase):
    def test_real_alert(self):
        self.assertIsNone(cr.drill_target(alert()))

    def test_drill_label_and_annotation(self):
        self.assertEqual(cr.drill_target(alert(drill="true", drill_pr="2301")), 2301)
        a = alert(drill="True")
        a["annotations"]["drill_pr"] = " 42 "
        self.assertEqual(cr.drill_target(a), 42)

    def test_drill_without_pr_is_an_error(self):
        with self.assertRaises(cr.RunError):
            cr.drill_target(alert(drill="true"))
        with self.assertRaises(cr.RunError):
            cr.drill_target(alert(drill="true", drill_pr="zero"))


class PickCandidate(unittest.TestCase):
    CUTOFF = "2026-10-05T16:00:00Z"

    def test_newest_touching_file_wins(self):
        prs = [pr(1, "2026-10-05T16:30:00Z"), pr(2, "2026-10-05T17:00:00Z"), pr(3, "2026-10-05T17:30:00Z", files=("tofu/x.tf",))]
        self.assertEqual(cr.pick_candidate(prs, TARGET_FILE, self.CUTOFF)["number"], 2)

    def test_window_and_revert_heads_excluded(self):
        prs = [pr(1, "2026-10-05T15:59:59Z"), pr(2, head="revert-chart-deadbeef"), pr(3, oid="")]
        self.assertIsNone(cr.pick_candidate(prs, TARGET_FILE, self.CUTOFF))

    def test_tolerates_junk(self):
        self.assertIsNone(cr.pick_candidate(["x", None, {}], TARGET_FILE, self.CUTOFF))


class ClassifyCommit(unittest.TestCase):
    def test_2254_is_pin_only_despite_comment_rewrite(self):
        self.assertEqual(cr.classify_commit(COMMIT_2254, TARGET_FILE), ("pin_only", "1.1.1", "2.0.8"))

    def test_values_edit_is_not_pin_only(self):
        patch = PATCH_2254.replace("     helm:", "-    singleNamespace: false\n+    singleNamespace: true\n     helm:")
        with self.assertRaises(cr.Outcome) as cm:
            cr.classify_commit([{"filename": TARGET_FILE, "patch": patch}], TARGET_FILE)
        self.assertEqual(cm.exception.outcome, "not_pin_only")

    def test_second_file_is_not_pin_only(self):
        files = COMMIT_2254 + [{"filename": "docs/adr.md", "patch": "@@ -1 +1 @@\n-a\n+b"}]
        with self.assertRaises(cr.Outcome) as cm:
            cr.classify_commit(files, TARGET_FILE)
        self.assertEqual(cm.exception.outcome, "not_pin_only")

    def test_wrong_single_file_is_not_pin_only(self):
        with self.assertRaises(cr.Outcome):
            cr.classify_commit([{"filename": "argocd/platform/loki.yaml", "patch": PATCH_2254}], TARGET_FILE)

    def test_comment_only_or_blank_line(self):
        comment_only = "@@ -1,2 +1,2 @@\n-    # old\n+    # new\n     targetRevision: 2.0.8"
        with self.assertRaises(cr.Outcome) as cm:
            cr.classify_commit([{"filename": TARGET_FILE, "patch": comment_only}], TARGET_FILE)
        self.assertEqual(cm.exception.outcome, "not_pin_only")
        blank = PATCH_2254.replace("+    targetRevision: 2.0.8", "+\n+    targetRevision: 2.0.8")
        with self.assertRaises(cr.Outcome):
            cr.classify_commit([{"filename": TARGET_FILE, "patch": blank}], TARGET_FILE)

    def test_two_pins_or_same_version(self):
        two = PATCH_2254.replace("+    targetRevision: 2.0.8", "+    targetRevision: 2.0.8\n+    targetRevision: 2.0.9")
        with self.assertRaises(cr.Outcome):
            cr.classify_commit([{"filename": TARGET_FILE, "patch": two}], TARGET_FILE)
        same = PATCH_2254.replace("-    targetRevision: 1.1.1", "-    targetRevision: 2.0.8 # x")
        with self.assertRaises(cr.Outcome):
            cr.classify_commit([{"filename": TARGET_FILE, "patch": same}], TARGET_FILE)

    def test_missing_patch_fails_closed(self):
        with self.assertRaises(cr.RunError):
            cr.classify_commit([{"filename": TARGET_FILE}], TARGET_FILE)
        with self.assertRaises(cr.RunError):
            cr.classify_commit([], TARGET_FILE)


class Shapes(unittest.TestCase):
    def test_branch_and_title(self):
        self.assertEqual(cr.revert_branch(SHA), "revert-chart-4bb522d3")
        self.assertEqual(cr.pr_title("argo-workflows", "2.0.8", "1.1.1", "ArgoControllerSilent"),
                         "revert: argo-workflows chart 2.0.8 → 1.1.1 (ArgoControllerSilent)")

    def test_body_last_line_is_the_memory_line(self):
        body = cr.pr_body("argo-workflows", "2.0.8", "1.1.1", "ArgoControllerSilent", "2026-10-05T17:40:00Z", 2254, "t", 120, False)
        self.assertEqual(body.splitlines()[-1], "reverted-charts: argo-workflows@2.0.8")
        self.assertIn("startsAt 2026-10-05T17:40:00Z", body)
        self.assertIn("DRILL", cr.pr_body("c", "2", "1", "ArgoControllerSilent", "t", 1, "t", 120, True))

    def test_pin_in_file(self):
        self.assertEqual(cr.pin_in_file("spec:\n  source:\n    targetRevision: 2.0.8 # c\n"), "2.0.8")
        with self.assertRaises(cr.RunError):
            cr.pin_in_file("no pin here")

    def test_metrics_render_every_outcome(self):
        text = cr.render_metrics({"reverted": 1}, {}, 0)
        for o in cr.OUTCOMES:
            self.assertIn(f'chart_revert_alerts_total{{outcome="{o}"}}', text)
        self.assertIn('chart_revert_alerts_total{outcome="reverted"} 1', text)
        self.assertIn("chart_revert_last_run_timestamp_seconds 0", text)
        self.assertIn('chart_revert_webhooks_total{result="queued"} 0', text)


class FakeRunner:
    """Scripted gh/git: `script` maps a command prefix (joined words) to (rc, stdout, stderr)."""

    def __init__(self, script, token="tok", master_pin="2.0.8"):
        self.script, self.token, self.master_pin, self.calls = script, token, master_pin, []

    def run(self, cmd, cwd=None, env=None, timeout=600):
        self.calls.append(cmd)
        joined = " ".join(cmd)
        for prefix, result in self.script.items():
            if joined.startswith(prefix):
                return result
        return 0, "", ""

    def read_token(self):
        if not self.token:
            raise cr.RunError("no token")
        return self.token

    def read_file(self, path):
        return f"    targetRevision: {self.master_pin}\n"

    def fresh_dir(self, path):
        pass


def ok_json(obj):
    import json
    return 0, json.dumps(obj), ""


HAPPY = {
    "gh pr list": ok_json([pr(), pr(2260, "2026-10-05T17:50:00Z", files=("docs/x.md",))]),
    "git -c http.extraHeader=Authorization: Basic": (2, "", ""),  # ls-remote: branch absent
    "gh api repos/teststuffstash/homelab/commits/" + SHA: ok_json({"files": COMMIT_2254}),
    "gh pr create": (0, "https://github.com/teststuffstash/homelab/pull/2300\n", ""),
}


class HandleAlert(unittest.TestCase):
    def test_reverted(self):
        r = FakeRunner(dict(HAPPY))
        outcome, reason = cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")
        self.assertEqual(outcome, "reverted", reason)
        joined = [" ".join(c) for c in r.calls]
        self.assertTrue(any(c.startswith("git clone -c http.extraHeader=Authorization: Basic") for c in joined))
        self.assertIn("git checkout -b revert-chart-4bb522d3", joined)
        self.assertIn(f"git revert --no-edit {SHA}", joined)
        self.assertIn("git push origin revert-chart-4bb522d3", joined)
        self.assertTrue(any(c.startswith("gh pr edit 2300 --repo teststuffstash/homelab --add-label automerge --add-label dependencies") for c in joined))
        self.assertIn("gh pr merge --auto --squash 2300 --repo teststuffstash/homelab", joined)
        self.assertFalse(any("--force" in c for c in joined))
        create = next(c for c in r.calls if c[:3] == ["gh", "pr", "create"])
        self.assertEqual(create[create.index("--body") + 1].splitlines()[-1], "reverted-charts: argo-workflows@2.0.8")
        self.assertNotIn("tok", " ".join(create))  # the token never lands in the PR

    def test_already_by_branch(self):
        s = dict(HAPPY)
        s["git -c http.extraHeader=Authorization: Basic"] = (0, f"{SHA}\trefs/heads/revert-chart-4bb522d3\n", "")
        r = FakeRunner(s)
        self.assertEqual(cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")[0], "already")
        self.assertFalse(any(c[:2] == ["git", "clone"] for c in r.calls))

    def test_already_by_master_pin(self):
        r = FakeRunner(dict(HAPPY), master_pin="1.1.1")
        outcome, _ = cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")
        self.assertEqual(outcome, "already")
        self.assertFalse(any(c[:2] == ["git", "push"] for c in r.calls))

    def test_no_candidate_outside_window(self):
        s = dict(HAPPY)
        s["gh pr list"] = ok_json([pr(merged="2026-10-05T15:00:00Z")])
        self.assertEqual(cr.handle_alert(alert(), FakeRunner(s), now=NOW, workdir="/tmp/x")[0], "no_candidate")

    def test_not_pin_only_never_clones(self):
        s = dict(HAPPY)
        s["gh api repos/teststuffstash/homelab/commits/" + SHA] = ok_json({"files": COMMIT_2254 + [{"filename": "README.md", "patch": "@@ -1 +1 @@\n-a\n+b"}]})
        r = FakeRunner(s)
        self.assertEqual(cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")[0], "not_pin_only")
        self.assertFalse(any(c[:2] == ["git", "clone"] for c in r.calls))

    def test_conflict_aborts_and_pushes_nothing(self):
        s = dict(HAPPY)
        s[f"git revert --no-edit {SHA}"] = (1, "", "CONFLICT (content)")
        r = FakeRunner(s)
        self.assertEqual(cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")[0], "conflict")
        self.assertIn(["git", "revert", "--abort"], r.calls)
        self.assertFalse(any(c[:2] == ["git", "push"] for c in r.calls))

    def test_unreadable_gh_is_error(self):
        s = dict(HAPPY)
        s["gh pr list"] = (1, "", "HTTP 502")
        self.assertEqual(cr.handle_alert(alert(), FakeRunner(s), now=NOW, workdir="/tmp/x")[0], "error")
        s["gh pr list"] = (0, "not json", "")
        self.assertEqual(cr.handle_alert(alert(), FakeRunner(s), now=NOW, workdir="/tmp/x")[0], "error")

    def test_no_token_is_error(self):
        r = FakeRunner(dict(HAPPY), token="")
        self.assertEqual(cr.handle_alert(alert(), r, now=NOW, workdir="/tmp/x")[0], "error")
        self.assertEqual(r.calls, [])

    def test_drill_targets_named_pr_outside_window(self):
        s = dict(HAPPY)
        old = pr(2254, merged="2026-10-01T00:00:00Z")
        s["gh pr view 2254"] = ok_json(old)
        r = FakeRunner(s)
        outcome, reason = cr.handle_alert(alert(drill="true", drill_pr="2254"), r, now=NOW, workdir="/tmp/x")
        self.assertEqual(outcome, "reverted", reason)
        self.assertFalse(any(c[:3] == ["gh", "pr", "list"] for c in r.calls))

    def test_drill_unmerged_or_wrong_file_is_not_reverted(self):
        s = dict(HAPPY)
        s["gh pr view 7"] = ok_json({**pr(7), "state": "OPEN"})
        self.assertEqual(cr.handle_alert(alert(drill="true", drill_pr="7"), FakeRunner(s), now=NOW, workdir="/tmp/x")[0], "error")
        s["gh pr view 8"] = ok_json(pr(8, files=("tofu/x.tf",)))
        self.assertEqual(cr.handle_alert(alert(drill="true", drill_pr="8"), FakeRunner(s), now=NOW, workdir="/tmp/x")[0], "no_candidate")

    def test_unknown_alertname(self):
        self.assertEqual(cr.handle_alert(alert(name="Other"), FakeRunner({}), now=NOW)[0], "no_candidate")


if __name__ == "__main__":
    unittest.main()
