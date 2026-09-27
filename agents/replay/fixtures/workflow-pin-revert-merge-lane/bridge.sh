# The content lines of the ORIGINAL (merged, now failing) pin PR's diff — two call sites of the
# same action, so the reverted set must de-duplicate to ONE pin; the `-` lines are the old pins
# and must NOT appear in it.
CONTENT_LINES='-      - uses: actions/create-github-app-token@d72941d797fd3113feb6b93fd0dec494b13a2547 # v1
+      - uses: actions/create-github-app-token@f45685208fd9b88321d74015b5996fc8c3e43d18 # v1.0.0
-        uses: actions/create-github-app-token@d72941d797fd3113feb6b93fd0dec494b13a2547 # v1
+        uses: actions/create-github-app-token@f45685208fd9b88321d74015b5996fc8c3e43d18 # v1.0.0'
