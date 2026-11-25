# ── bridge ── the per-repo loop variables the FU-143 goal-child block holds by the time it runs.
# Every name is a SCAN name (`slug`, `repo`, `orphans`, `c6g`, `c6g_nums`) — a bridge that invents
# one pins a different clause. `ib_get`/`ib_body`/`ib_rows`/`ISSUE_LIST_LIMIT` come from the
# config-defaults block run.sh prepends to every composition sourced from coordinator-scan.sh;
# `strong_link_count`/`strong_link_pr` and `pr_blocked_on_check` come from the parts above.
slug="teststuffstash/homelab"
repo="homelab"
orphans=""
c6g=""
c6g_nums=""
# GitHub's own LIST semantics for `gh pr list --state merged` (homelab#3309). The stub serves one
# recorded file whatever the flags; GitHub filters server-side by `--base` and returns the first
# `--limit` PRs in CREATION order, newest first (the recorded file's order). Modelled here so a
# row can pin the window: a merge older than the newest N is invisible to an unscoped read.
gh() {
  case " $* " in *" pr list "*" --state merged "*) ;; *) command gh "$@"; return ;; esac
  local _b="" _l="30" _p="" _a
  for _a in "$@"; do
    case "$_p" in --base) _b="$_a" ;; --limit) _l="$_a" ;; esac
    _p="$_a"
  done
  command gh "$@" | jq -c --arg b "$_b" --argjson l "$_l" '[.[] | select($b == "" or .baseRefName == $b)] | .[0:$l]'
}
