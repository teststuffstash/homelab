"""agents/update-pr-branch.sh, ported: functional core (pure predicates over the typed board) +
one imperative shell (`run`) that fetches, decides, applies and prints the bash's OUT lines.

The bash script is the ORACLE: same gh calls in the same order, same stdout, same exit code.
Where the bash's semantics are odd they are matched, not fixed — each such spot says `MATCHES
BASH` with the line ref, and REPORT.md lists them.

    GH_TOKEN=<homelab-merge App token> python3 updater.py <owner/repo>
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Literal

from gh_types import Commit, PrCommitsReviews, PullRequest, RenovateProbe, RollupEntry
from github import (AddLabel, CreateLabel, GitHub, GitHubError, PatchBody, RemoveLabel,
                    UpdateBranch)

# ── configuration (the env the script reads) ─────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class Config:
    reviewer_login: str = "homelab-reviewer"  # REVIEWER_LOGIN — read by arm 2 ONLY (bash :41/:264)
    merge_ready_only: bool = True  # UPDATER_MERGE_READY_ONLY != "0" (bash :46)

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Config:
        return cls(reviewer_login=env.get("REVIEWER_LOGIN") or "homelab-reviewer",
                   merge_ready_only=(env.get("UPDATER_MERGE_READY_ONLY") or "1") != "0")


def jq_text(v: str | None) -> str:
    """What `jq -r '.field'` prints for a string-or-null: a null is the TEXT "null"."""
    return "null" if v is None else v


def jq_max(vals: Iterable[str | None]) -> str | None:
    """jq `max` over strings-or-nulls: null sorts below every string; [] → null."""
    strs = [v for v in vals if v is not None]
    return max(strs) if strs else None


# ── functional core: leg domains (LEG_DOMAINS_JQ, bash :202-211) ─────────────────────────────────


def breakered(pr: PullRequest) -> bool:
    names = pr.label_names
    return "agent/error" in names or "agent/arbitrate" in names


def leg1_candidate(pr: PullRequest) -> bool:
    """armed ∧ BEHIND ∧ ¬CR ∧ (¬REVIEW_REQUIRED ∨ no bot APPROVED in latestReviews) — a PROBE-COST
    pre-filter, not an admission rule (bash :173-199). Hard-coded `homelab-reviewer` prefix, NOT
    $REVIEWER_LOGIN — MATCHES BASH :208."""
    if not (pr.armed and pr.merge_state_status == "BEHIND" and pr.review_decision != "CHANGES_REQUESTED"):
        return False
    if pr.review_decision != "REVIEW_REQUIRED":
        return True
    return not any((r.login or "").startswith("homelab-reviewer") and r.state == "APPROVED"
                   for r in pr.latest_reviews)


def leg2_domain(pr: PullRequest) -> bool:
    return pr.armed and pr.merge_state_status == "BEHIND" and pr.review_decision == "CHANGES_REQUESTED"


def sweep_domain(pr: PullRequest) -> bool:
    """Leg 1b: armed ∧ ¬leg1 ∧ ¬leg2 ∧ ¬breakered (bash :359)."""
    return pr.armed and not leg1_candidate(pr) and not leg2_domain(pr) and not breakered(pr)


# ── functional core: the Renovate predicate (agents/renovate-currency.sh) ────────────────────────


def renovate_login(login: str | None) -> bool:
    """`(. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "") | startswith("homelab-renovate")`."""
    s = login or ""
    s = s.removeprefix("app/")
    s = s.removesuffix("[bot]")
    return s.startswith("homelab-renovate")


def renovate_author(pr: PullRequest) -> bool:
    return renovate_login(None if pr.author is None else pr.author.login)


def renovate_untouched(commits: tuple[Commit, ...] | None) -> bool:
    """Every non-merge commit's every author is Renovate. `all([])` is TRUE: no commits, or commits
    with no `authors`, read UNTOUCHED — MATCHES renovate-currency.sh:74-77."""
    return all(renovate_login(a.login) for c in (commits or ()) if not c.is_merge for a in c.authors)


def renovate_merged_into(commits: tuple[Commit, ...] | None) -> bool:
    return any(not renovate_login(a.login) for c in (commits or ()) if c.is_merge for a in c.authors)


def renovate_green(rollup: tuple[RollupEntry, ...]) -> bool:
    """Every check clean; a CANCELLED entry dropped when a same-named sibling is not CANCELLED;
    absent = not green (renovate-currency.sh:54-59)."""
    groups: dict[str, list[str]] = {}
    for e in rollup:
        groups.setdefault(e.key, []).append(e.value)
    vals: list[str] = []
    for vs in groups.values():
        vals += [v for v in vs if v != "CANCELLED"] if any(v != "CANCELLED" for v in vs) else vs
    return len(vals) > 0 and all(v in ("SUCCESS", "NEUTRAL", "SKIPPED") for v in vals)


_IN_FLIGHT = {"QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", ""}


def renovate_red(rollup: tuple[RollupEntry, ...]) -> bool:
    """A CONCLUDED red: ≥1 check, none in flight, not green (renovate-currency.sh:66-72)."""
    return len(rollup) > 0 and not any(e.value in _IN_FLIGHT for e in rollup) and not renovate_green(rollup)


RenovateGate = Literal["admit", "skip", "handback"]


def renovate_gate(probe: RenovateProbe) -> RenovateGate:
    """Leg 1's Renovate fork (bash :224-233): untouched ∧ ¬green → merged-into? hand back : skip;
    anything else falls through to the ordinary admission."""
    if renovate_untouched(probe.commits) and not renovate_green(probe.rollup):
        return "handback" if renovate_merged_into(probe.commits) else "skip"
    return "admit"


TICKED = "- [x] <!-- rebase-check -->"
UNTICKED = "- [ ] <!-- rebase-check -->"


def handback_body(body: str) -> Literal["ticked", "nobox"] | str:
    """renovate_handback's body decision. grep -q is line-wise but the needle has no newline, so
    a substring test is exact; sed replaces the FIRST hit on EACH line."""
    if TICKED in body:
        return "ticked"
    if UNTICKED not in body:
        return "nobox"
    return "\n".join(line.replace(UNTICKED, TICKED, 1) for line in body.split("\n"))


# ── functional core: leg 1 admission ─────────────────────────────────────────────────────────────

Snapshot = Literal["ready", "park", "not-ready"] | tuple[Literal["probe"], str]


def bot_approved_at(pr: PullRequest, reviewer_login: str) -> str:
    """Newest `reviews[]` APPROVED by the bot (login `[bot]`-stripped, EXACT match) — "" if none."""
    return jq_max(r.submitted_at for r in pr.reviews
                  if (r.login or "").removesuffix("[bot]") == reviewer_login and r.state == "APPROVED") or ""


def leg1_snapshot(pr: PullRequest, cfg: Config) -> Snapshot:
    """The part of leg 1's admission the snapshot alone decides (bash :235-267)."""
    if not cfg.merge_ready_only or jq_text(pr.review_decision) == "APPROVED":
        return "ready"
    if jq_text(pr.review_decision) == "REVIEW_REQUIRED":
        return "park"
    if jq_text(pr.review_decision) == "" and "automerge" in pr.label_names:
        return "ready"
    at = bot_approved_at(pr, cfg.reviewer_login)
    return ("probe", at) if at else "not-ready"


def approved_at_head(approved_at: str, commits: tuple[Commit, ...]) -> bool:
    """`$a > (newest non-merge committedDate // "")` (bash :277-279)."""
    return approved_at > (jq_max(c.committed_date for c in commits if not c.is_merge) or "")


def lanes(prs: tuple[PullRequest, ...], ready: set[int]) -> list[list[PullRequest]]:
    """`group_by(.baseRefName // "") | map(sort_by(.createdAt))` — lanes in ascending base order,
    members oldest-first (stable)."""
    by_base: dict[str, list[PullRequest]] = {}
    for pr in prs:
        if pr.number in ready:
            by_base.setdefault(pr.base_ref_name or "", []).append(pr)
    return [sorted(by_base[b], key=lambda p: p.created_at) for b in sorted(by_base)]


# ── functional core: leg 2 verdict, leg 3 sweep ──────────────────────────────────────────────────


def leg2_verdict(pc: PrCommitsReviews) -> Literal["yes", "no", "hold"]:
    """The unstrand jq (bash :390-396). It has NO `// ""` guards, so a null commits/reviews list,
    a null messageHeadline or a review with a null author is a jq ERROR → HOLD — MATCHES BASH
    (leg 1's equivalent reads are null-safe; see REPORT)."""
    if pc.commits is None or pc.reviews is None:
        return "hold"
    if any(c.message_headline is None for c in pc.commits):
        return "hold"
    if any(r.login is None for r in pc.reviews):
        return "hold"
    c = jq_max(x.committed_date for x in pc.commits if not x.is_merge)
    v = jq_max(r.submitted_at for r in pc.reviews
               if r.login.startswith("homelab-reviewer") and r.state in ("APPROVED", "CHANGES_REQUESTED"))
    return "yes" if (c is not None and v is not None and c > v) else "no"


Leg3 = tuple[Literal["label"], int] | tuple[Literal["unlabel"], int]


def leg3_actions(prs: tuple[PullRequest, ...]) -> list[Leg3]:
    out: list[Leg3] = []
    for pr in prs:
        has = "merge-conflict" in pr.label_names
        if pr.armed and pr.merge_state_status == "DIRTY":
            if not has:
                out.append(("label", pr.number))
        elif has:
            out.append(("unlabel", pr.number))
    return out


# ── imperative shell ─────────────────────────────────────────────────────────────────────────────

HOLD = "commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)"


def _renovate_probe(gh: GitHub, repo: str, pr: PullRequest) -> RenovateProbe | None:
    """renovate_probe: commits, then (only with a head oid) check-runs, then statuses; ANY leg
    unreadable → None (the caller HOLDS)."""
    try:
        commits = gh.pr_commits(repo, pr.number).commits
        if not pr.head_ref_oid:
            return None
        runs = gh.check_runs(repo, pr.head_ref_oid)
        statuses = gh.commit_statuses(repo, pr.head_ref_oid)
    except GitHubError:
        return None
    return RenovateProbe(commits=commits, rollup=runs + statuses)


def _handback(gh: GitHub, repo: str, n: int, prefix: str, out: Callable[[str], None]) -> None:
    what = f"{prefix} #{n} Renovate-authored, merged into, not merge-ready"
    try:
        body = gh.pr_body(repo, n)
    except GitHubError:
        out(f"{what} — body unreadable, HOLDING the hand-back (rule #6; the next pass retries)")
        return
    new = handback_body(body)
    if new == "ticked":
        out(f"{what} — rebase already requested (box ticked); Renovate's next run takes it back")
    elif new == "nobox":
        out(f"{what} — no rebase checkbox in the body; human check (close + delete the branch, docs/renovate.md)")
    else:
        try:
            gh.write(PatchBody(repo, n, new))
            out(f"{what} — handed back to Renovate (rebase box ticked; its next run rebuilds the branch)")
        except GitHubError:
            out(f"{what} — could not tick the rebase box; the next pass retries")


def run(gh: GitHub, repo: str, env: Mapping[str, str],
        out: Callable[[str], None], err: Callable[[str], None]) -> int:
    """One pass. `out` gets stdout lines; `err` gets raw stderr text the bash would let through
    (gh's own stderr on the pr list and the two update-branch PUTs — every other site 2>/dev/null)."""
    cfg = Config.from_env(env)
    tag = f"updater[{repo}]:"
    try:
        prs = gh.pr_list(repo)
    except GitHubError as e:  # bash: `PRS="$(gh pr list …)"` under set -e → exit gh's rc
        if e.rc != 0:
            err(e.stderr)
            return e.rc
        # rc 0 but not the board: bash dies in the next jq (rc + message are jq-version text)
        err(f"updater: gh pr list body unreadable: {e}\n")
        return 2

    # ── leg 1: per-candidate admission (list order) ──
    ready: set[int] = set()
    for pr in (p for p in prs if leg1_candidate(p)):
        n = pr.number
        commits: tuple[Commit, ...] | None = None
        if renovate_author(pr):
            probe = _renovate_probe(gh, repo, pr)
            if probe is None:
                out(f"{tag} #{n} {HOLD}")
                continue
            commits = probe.commits
            gate = renovate_gate(probe)
            if gate == "handback":
                _handback(gh, repo, n, tag, out)
                continue
            if gate == "skip":
                out(f"{tag} #{n} Renovate-authored, untouched and not green — Renovate's to rebase "
                    "(rebaseWhen behind-base-branch, ADR-153); skipping")
                continue
        snap = leg1_snapshot(pr, cfg)
        if snap == "ready":
            ready.add(n)
            continue
        if snap in ("park", "not-ready"):
            continue
        _, approved_at = snap
        if commits is None:
            try:
                commits = gh.pr_commits(repo, n).commits
            except GitHubError:
                commits = None
        if commits is None:
            out(f"{tag} #{n} {HOLD}")
            continue
        if approved_at_head(approved_at, commits):
            ready.add(n)

    picked = lanes(prs, ready)
    if picked:
        for lane in picked:  # ONE update lands per lane; a failed attempt hops to the next member (#2203)
            hop = False
            for member in lane:
                n = member.number
                out(f"{tag} updating #{n} (lane hop — the lane's older member did not clear)" if hop else
                    f"{tag} updating #{n} (oldest armed+BEHIND, FIFO)")
                try:
                    res = gh.write(UpdateBranch(repo, n, member.head_ref_oid or ""))
                except GitHubError as e:
                    err(e.stderr)
                    out(f"{tag} update of #{n} failed (422) — skipping; next pass retries")
                    hop = True
                    continue
                if res.stderr:
                    err(res.stderr)
                break
    else:
        out(f"{tag} no armed+BEHIND PR to update")

    # ── leg 1b: the hand-back sweep over the complement ──
    for pr in (p for p in prs if sweep_domain(p)):
        if not renovate_author(pr):
            continue
        probe = _renovate_probe(gh, repo, pr)
        if probe is None:
            out(f"handback[{repo}]: #{pr.number} commit probe unreadable — HOLDING (rule #6; the */15 cron retries)")
            continue
        if not (renovate_untouched(probe.commits) and renovate_merged_into(probe.commits)):
            continue
        if renovate_red(probe.rollup) or jq_text(pr.review_decision) == "CHANGES_REQUESTED":
            _handback(gh, repo, pr.number, f"handback[{repo}]:", out)

    # ── leg 2: the CR∧BEHIND unstrand ──
    for pr in (p for p in prs if leg2_domain(p) and not breakered(p)):
        n = pr.number
        try:
            pc: PrCommitsReviews | None = gh.pr_commits_reviews(repo, n)
        except GitHubError:
            pc = None  # rc≠0, empty, or not the JSON shape: every one of them HOLDs below
        if pc is not None and renovate_author(pr) and renovate_untouched(pc.commits):
            if renovate_merged_into(pc.commits):
                _handback(gh, repo, n, "unstrand:", out)
            else:
                out(f"unstrand: #{n} Renovate-authored and untouched — Renovate rebases it itself "
                    "(rebaseWhen behind-base-branch, ADR-153); skipping")
            continue
        verdict = "hold" if pc is None else leg2_verdict(pc)
        if verdict == "yes":
            out(f"unstrand: updating CR-and-behind PR #{n} (new content since verdict)")
            try:
                res = gh.write(UpdateBranch(repo, n, pr.head_ref_oid or ""))
                if res.stderr:
                    err(res.stderr)
            except GitHubError as e:
                err(e.stderr)
                out(f"unstrand: update of #{n} failed (422) — skipping; next pass retries")
        elif verdict == "no":
            out(f"unstrand: #{n} CR-and-behind but NO new content since the verdict — nothing to "
                "re-review, not updating (2026-08-17 narrowing)")
        else:
            out(f"unstrand: #{n} commit/review probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")

    # ── leg 3: the conflict labeler ──
    for kind, n in leg3_actions(prs):
        if kind == "label":
            create_err = ""
            try:
                gh.write(CreateLabel(repo, "merge-conflict", "e11d21",
                                     "PR branch conflicts with master — updater can't auto-resolve"))
            except GitHubError as e:
                create_err = e.stderr.rstrip("\n")
            try:
                gh.write(AddLabel(repo, n, "merge-conflict"))
            except GitHubError as e:
                # gh_label_add's own stderr line, captured by label_conflict's 2>&1
                add_err = (f"gh_label_add: {repo}#{n} +merge-conflict FAILED (rc={e.rc}): "
                           f"{e.stderr.rstrip(chr(10)) or 'gh gave no output'}")
                out(f"{tag} could not label #{n} merge-conflict — {add_err}"
                    f"{f' (label create: {create_err})' if create_err else ''} — the */15 pass retries")
        else:
            try:  # best-effort clear, every failure swallowed (bash :426 `2>/dev/null || true`)
                gh.write(RemoveLabel(repo, n, "merge-conflict"))
            except GitHubError:
                pass
    return 0


def main(argv: list[str]) -> int:
    from github import GhCli

    if len(argv) < 2 or not argv[1]:
        print("update-pr-branch: usage: updater.py <owner/repo>", file=sys.stderr)
        return 1
    return run(GhCli(), argv[1], os.environ,
               out=lambda s: print(s, flush=True),
               err=lambda s: (sys.stderr.write(s), sys.stderr.flush()))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
