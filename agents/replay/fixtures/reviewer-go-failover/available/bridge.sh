# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub.
# The /route call (above this block in the shipped script) resolved the model decision — the router
# dispatched with a Go-rail model (subscription latched, Go available). _router_adopted=1 means the
# routed verdict REPLACED the model, so the legacy ladder is skipped. This block passes through
# silently — the model (opencode-go/qwen3.5-plus) is already set from the route response.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="opencode-go/qwen3.5-plus"
GO_SERVED=1
_router_adopted=1