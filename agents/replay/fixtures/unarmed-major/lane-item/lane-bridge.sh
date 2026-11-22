# three dispatch sites in one run: the block is re-entered per (clause, repo, item)
um_lane_side="$IN_SIDE"
lane_rows="unarmed-major|homelab|pr-3233 unarmed-major|sleep-tracking|pr-191 unarmed-major|homelab|pr-30 ci-red|homelab|pr-3233"
for lane_row in $lane_rows; do
  uclause="${lane_row%%|*}"; lane_rest="${lane_row#*|}"; urepo="${lane_rest%%|*}"; uitem="${lane_rest#*|}"
