# The EXON_TARGETS line workflow-pin-revert-exonerate emits for snore-recorder#64, split the way the
# template's restore loop reads it (IFS='|'), and the branch that loop pushed.
IFS='|' read -r XSLUG XREV XRSHA XORIG XWF XBRANCH XPINS <<< 'teststuffstash/snore-recorder|64|1ceaa31cc9f41c011553ae108d39e0185033b43b|63|build-image|master|actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510'
XBR="revert-wf-${XRSHA:0:8}"
