# bridge — run the REAL updater script against the stubbed world. Invoked by path (extraction's
# stronger cousin: nothing is copied, so nothing can drift), repo pinned to the fixture universe.
bash "$REPLAY_ROOT/agents/update-pr-branch.sh" teststuffstash/testrepo
