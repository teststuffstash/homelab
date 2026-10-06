# ── observation point ── the reader's declared set (the janitor brief) and the emitter's wiring to
# it. The assertion is the round-trip: the surfaces the READER declares are the surfaces the
# EMITTER names, and the review-body surface is among them (homelab#1776). `SURFACE` is the row's
# slug (issue-comments | pr-bodies | pr-review-bodies); the declared strings are slugged the same
# way before the membership test, so the row names a surface, not a spelling.
rc=0
SURFACES="$(tool_gap_surfaces "$BRIEF")" || rc=$?
echo "reader-rc: $rc"
if [ "$rc" = 0 ]; then
  echo "reader-surfaces: $(printf '%s' "$SURFACES" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  HIT=no
  while IFS= read -r s; do
    [ "$(printf '%s' "$s" | tr 'A-Z ' 'a-z-')" = "$SURFACE" ] && HIT=yes
  done <<< "$SURFACES"
  if [ "$HIT" = yes ]; then echo "reader-reads: $SURFACE"; else echo "reader-misses: $SURFACE"; fi
fi
if grep -qF '${TOOL_GAP_SURFACES}' "$EMITTER"; then echo "emitter-wired: yes"; else echo "emitter-wired: no"; fi
exit 0