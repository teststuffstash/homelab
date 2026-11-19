"""Gate a major dependency handoff on the review at the current content head."""

import os
import re
import sys
from urllib.parse import quote

from . import gh
from .handoff_read import UnreadablePR, read_handoff_pr


def main(slug: str, pr: str) -> int:
    item = f"{slug}#{pr}"
    bot = os.environ.get("REVIEWER_LOGIN", "homelab-reviewer")
    claim, handoff = "agent/in-progress", "major/awaiting-human"

    def report(kind: str, message: str, rc: int) -> int:
        print(f"major-handoff: {kind}{message}")
        return rc

    try:
        data = read_handoff_pr(slug, pr)
    except UnreadablePR as exc:
        return report("UNREADABLE — ", f"gh pr view {item} {exc} — nothing written", 4)

    def refuse(message: str) -> int:
        return report("REFUSED — ", message, 3)

    if data.state != "OPEN":
        return refuse(f'{item} is {data.state or "of unknown state"}, not OPEN')
    if "major" not in data.labels:
        return refuse(f"{item} does not carry the `major` label — not the human-merge lane")
    approvals = [r for r in data.reviews if (r.login or "").removesuffix("[bot]") == bot and r.state == "APPROVED"]
    if not approvals:
        return refuse(f"no APPROVED review by {bot} on {item} — dispatch the reviewer (brief step 2)")
    approval = max(approvals, key=lambda r: r.submitted_at)
    approved_at = approval.submitted_at
    newest = max((c.committed_at for c in data.commits if not c.headline.startswith(("Merge branch ", "Merge remote-tracking branch ", "Merge pull request "))), default="")
    if approved_at <= newest:
        return refuse(f"the newest {bot} approval ({approved_at}) predates the newest content commit ({newest}) on {item} — the verdict is not at head; re-dispatch the reviewer (brief step 2)")
    body = approval.body.replace("\r\n", "\n").replace("\r", "\n")
    missing = [h for h in ("Upstream", "Known issues", "Platform compatibility", "Evidence") if not re.search(r"^[ \t]*(?:#{1,6}[ \t]+|\*\*)[ \t]*" + re.escape(h) + r"(?:[ \t]|:|\*\*|$)", body, re.I | re.M)]
    if missing:
        return refuse(f"the approval at head ({approved_at}) lacks the migration heading(s): {', '.join(missing)} — re-dispatch the reviewer (brief step 2)")
    base = f"repos/{slug}/issues/{pr}/labels"
    remove = ("api", "-X", "DELETE", f"{base}/{quote(claim, safe='')}")

    def rm_label() -> int:  # an already-absent label is success, as gh_label_rm in agents/machine-comment.sh
        r = gh.run(*remove)
        gone = "Label does not exist" in r.stderr and "(HTTP 404)" in r.stderr
        return 0 if r.returncode == 0 or gone else r.returncode

    if re.search(r"^[ \t]*appVersion:[ \t]*unchanged\b", body, re.I | re.M):
        if gh.run("pr", "merge", pr, "--repo", slug, "--auto", "--squash").returncode:
            return report("END STATE NOT PROVEN — ", f"arming auto-merge on {item} FAILED (packaging-only chart major); {claim} left in place", 5)
        if rm_label():
            return report("END STATE NOT PROVEN — ", f"auto-merge armed on {item} but removing {claim} FAILED", 5)
        after = gh.run("api", f"repos/{slug}/pulls/{pr}", "--jq", r'"\(.auto_merge != null) \([.labels[].name] | join(","))"')
        if after.returncode:
            return report("END STATE NOT PROVEN — ", f"auto-merge armed on {item} and {claim} removed, but the pull re-read failed", 5)
        armed, _, label_text = after.stdout.strip().partition(" ")
        if armed != "true" or claim in label_text.split(","):
            return report("END STATE NOT PROVEN — ", f"{item} after the writes: auto_merge={armed} labels={label_text}", 5)
        return report("", f"{item} → ARMED (packaging-only chart major: appVersion unchanged; {claim} removed; {bot} approval at head, submitted {approved_at})", 0)
    if gh.run("api", "-X", "POST", base, "-f", f"labels[]={handoff}").returncode:
        return report("END STATE NOT PROVEN — ", f"adding {handoff} on {item} FAILED; {claim} left in place", 5)
    if rm_label():
        return report("END STATE NOT PROVEN — ", f"{handoff} added on {item} but removing {claim} FAILED", 5)
    after = gh.run("api", base, "--jq", ".[].name")
    if after.returncode:
        return report("END STATE NOT PROVEN — ", f"both writes issued on {item} but the label re-read failed", 5)
    labels = after.stdout.splitlines()
    if handoff not in labels or claim in labels:
        return report("END STATE NOT PROVEN — ", f"{item} labels after the writes: {','.join(labels)}", 5)
    return report("", f"{item} → {handoff} ({claim} removed; {bot} approval at head, submitted {approved_at})", 0)


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
