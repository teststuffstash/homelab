# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude and that the ConfigMap was created (off argv).
if grep -q '^mkdir -p /work/context; ' <<< "$RUN_CMD"; then
  echo "→ prelude prepend verified: RUN_CMD starts with mkdir -p /work/context"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi
if grep -q 'OUTSIDER-INJECTION' <<< "${PF_ISSUE_MD}${PF_REVIEWS_MD}${PF_ARB_MD}"; then
  echo "→ untrusted-comment filter FAILED: outsider text reached the bundle"
else
  echo "→ untrusted-comment filter verified: no outsider text in issue/reviews/arbitration"
fi
if grep -q 'TRUSTED-RULING' <<< "$PF_ARB_MD"; then
  echo "→ trusted ARBITRATE verified: the collaborator ruling won over newer outsider ones"
else
  echo "→ trusted ARBITRATE FAILED: PF_ARB_MD=[${PF_ARB_MD}]"
fi
