# ── bridge ── the resolve-loop variables the engagement split reads. Every name is set EARLIER in
# responder-argo.yaml's own resolve loop: `$rfp`/`$rname` from the resolved alert, `$hit`/`$rrepo`/
# `$rnum` from the alert-fp search, `$rmeta` from the REST issue read. The block `continue`s on an
# unreadable probe, so the bridge opens the loop it lives in and `post.sh` closes it.
rfp="4cafb4ee21e29ace"
rname="PodSigkilled"
hit="teststuffstash/homelab#1723"
rrepo="teststuffstash/homelab"
rnum="1723"
rmeta='{"number":1723,"state":"open","body":"~10.5h nx-01 node outage, not a per-pod OOM.\n\nalert-fp:4cafb4ee21e29ace\nfix-verdict: report-only\n"}'

# `date` is shimmed to a constant: the bots-only branch interpolates $(date -u …) into its comment
# body, and a wall-clock stamp in an asserted action stream is a fixture that reds at midnight.
# Same seam-redefinition pattern the family already uses for `curl`, `ib` and `mc_now`.
date() { printf '2026-09-16T07:19:05Z'; }

# `_record_clear` is defined ABOVE this block in responder-argo.yaml and is not clause code under
# test here — the branch's contract is WHICH of the two paths it takes, not how the body line is
# written (the `fix`-verdict branch one level up already exercises that helper). Shimmed to record
# its call in the same action stream the gh/kubectl stubs write, so "no comment, body line instead"
# is asserted in one vocabulary.
_record_clear() { printf 'CALL _record_clear %s %s %s %s\n' "$1" "$2" "$4" "$5" >> "$REPLAY_ACTIONS"; return 0; }

for _ in 1; do
