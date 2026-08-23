# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub.
# The /route call (above this block in the shipped script) resolved the model decision — the router
# returned a deferral (subscription limited, Go rail also limited). _router_defer=1 and _rwhy carry
# the reason. This block exits with the deferral message.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="sonnet"
GO_SERVED=0
_router_defer=1
_rwhy="subscription-limited:latched"
# The route call above returned a typed defer — both subscription and Go rails are limited.