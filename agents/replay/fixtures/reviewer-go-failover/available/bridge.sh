# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub.
# The /route call (above this block in the shipped script) resolved the model decision — the router
# picked from the Go rail when the subscription was latched. _router_defer is unset (dispatch),
# so this block passes through silently (the model is already set from the route response).
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="sonnet"
GO_SERVED=0
_router_defer=""
# The model was resolved by the route call above — the router dispatched with a Go-rail model.