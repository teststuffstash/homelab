# Observation point: after the context-prefetch block runs, assert that the dispatch was deferred.
# The block should exit 0 (deferral) before reaching the post.sh assertions.
echo "→ dispatch deferred — directive unreadable (reviews verdict required for fix round)"
echo "→ prelude prepend NOT REACHED (deferred before RUN_CMD modification)"
RC 0