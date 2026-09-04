# ── observation point ── not launcher code. The finished variable state is the observable.
# Each row outputs the final values of MODEL, MODEL_RAIL, MODEL_HARNESS, and HARNESS
# so the action stream pins the block's effect.
echo "MODEL='${MODEL-}'"
echo "MODEL_RAIL='${MODEL_RAIL-}'"
echo "MODEL_HARNESS='${MODEL_HARNESS-}'"
echo "HARNESS='${HARNESS-}'"
echo "OPENCODE_MODEL='${OPENCODE_MODEL-}'"