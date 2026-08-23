# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub.
# The /route call (above this block in the shipped script) resolved the model decision — the router
# dispatched with a subscription model. But MODEL_SET_EXPLICIT=1 (operator passed --model=opus),
# so the ADR-096 override rule kept opus. _router_adopted=1 means the routed verdict replaced the
# model, but the explicit --model wins. This block passes through silently.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="opus"  # Explicit model pinned by operator
MODEL_SET_EXPLICIT=1
GO_SERVED=0
_router_adopted=1