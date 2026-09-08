# Observe the printed depth per chain (the tree + the expected values are in fixture.yaml).
_d=$(sprout-depth-walk 11 "$REPO_SLUG"); echo "chain_a goal>child depth=$_d"
_d=$(sprout-depth-walk 21 "$REPO_SLUG"); echo "chain_b goal>theme>child depth=$_d"
_d=$(sprout-depth-walk 22 "$REPO_SLUG"); echo "chain_c goal>theme>child>sprout depth=$_d"
_d=$(sprout-depth-walk 12 "$REPO_SLUG"); echo "chain_d goal>child>sprout depth=$_d"
# chain e: the theme's TITLE read fails (per-call injection, homelab#740) — the hop must count.
export STUB_GH_api_repos_teststuffstash_test_project_issues_20=fail
_d=$(sprout-depth-walk 21 "$REPO_SLUG"); echo "chain_e goal>theme(title unreadable)>child depth=$_d"
unset STUB_GH_api_repos_teststuffstash_test_project_issues_20
_d=$(sprout-depth-walk 31 "$REPO_SLUG"); echo "chain_f goal>THEME-caps-space>child depth=$_d"
_d=$(sprout-depth-walk 41 "$REPO_SLUG"); echo "chain_g goal>post-launch>child depth=$_d"
echo "sprout_depth_walk_executed=1"
