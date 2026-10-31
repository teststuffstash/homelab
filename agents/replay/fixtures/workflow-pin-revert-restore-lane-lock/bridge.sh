# The EXON_TARGETS line workflow-pin-revert-exonerate emits for its lock-revert row (#64 on
# `revert-lock-161afc12`, `reverted-locks: qrencode@4.1.99`), split the way the template's restore
# loop reads it (IFS='|'), and the branch that loop pushed (the revert's own prefix + its sha8).
IFS='|' read -r XSLUG XREV XRSHA XORIG XWF XBRANCH XPINS XKIND XPFX <<< 'teststuffstash/snore-recorder|64|1ceaa31cc9f41c011553ae108d39e0185033b43b|63|build-image|master|qrencode@4.1.99|locks|revert-lock-'
XBR="${XPFX}${XRSHA:0:8}"
