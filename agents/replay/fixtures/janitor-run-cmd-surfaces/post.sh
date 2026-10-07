# ── observation point ── the RUN_CMD's sweep-6 clause: does it read the surfaces from the brief's
# single `TOOL_GAP_SURFACES:` declaration, or does it restate them? The assertion is the
# round-trip: the surfaces the BRIEF declares are the surfaces the RUN_CMD makes reachable, and
# the RUN_CMD does NOT restate any surface literal (one declaration, no second copy — homelab#2286).
# `SURFACE` is the row's slug (issue-comments | pr-bodies | pr-review-bodies); the declared strings
# are slugged the same way before the membership test.
rc=0
SURFACES="$(sed -n 's/^[[:space:]]*TOOL_GAP_SURFACES:[[:space:]]*//p' "$BRIEF" 2>/dev/null | head -1)" || rc=$?
echo "brief-rc: $rc"
if [ "$rc" = 0 ] && [ -n "$SURFACES" ]; then
  echo "brief-surfaces: $SURFACES"
  HIT=no
  while IFS= read -r s; do
    s="$(printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z ' 'a-z-')"
    [ "$s" = "$SURFACE" ] && HIT=yes
  done <<< "$(printf '%s' "$SURFACES" | tr ',' '\n')"
  if [ "$HIT" = yes ]; then echo "surface-reachable: $SURFACE"; else echo "surface-missing: $SURFACE"; fi
fi
# One declaration: the RUN_CMD references the brief's TOOL_GAP_SURFACES line
if grep -qF 'TOOL_GAP_SURFACES' <<< "$RUN_CMD"; then
  echo "cmd-refs-brief: yes"
else
  echo "cmd-refs-brief: no"
fi
# No second copy: the RUN_CMD does NOT restate specific surfaces
if grep -qF 'issue comments + PR bodies' <<< "$RUN_CMD"; then
  echo "cmd-restates-surfaces: yes"
else
  echo "cmd-restates-surfaces: no"
fi
exit 0