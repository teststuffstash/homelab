# The content lines of the ORIGINAL (merged, now stuck) image PR's diff — the dind tag moved on
# two container blocks (the same ref twice), so the reverted set must de-duplicate to ONE ref; the
# `-` lines are the old refs and must NOT appear in it.
CONTENT_LINES='-          image = "docker:27-dind"
+          image = "docker:29-dind"
-          image = "docker:27-dind"
+          image = "docker:29-dind"'
