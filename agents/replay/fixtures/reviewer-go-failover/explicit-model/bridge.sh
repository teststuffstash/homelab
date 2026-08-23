# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub.
# The /route call (above this block in the shipped script) resolved the model decision — the router
# dispatched with the subscription model. An explicit --model was passed (MODEL_SET_EXPLICIT=1),
# so the ADR-096 override rule kept the explicit model. _router_defer is unset (dispatch),
# so this block passes through silently.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="opus"  # Explicit model pinned by operator
MODEL_SET_EXPLICIT=1
GO_SERVED=0
_router_defer=""
# The model was resolved by the route call above — the router dispatched with a subscription model,
# but the explicit --model override kept opus.