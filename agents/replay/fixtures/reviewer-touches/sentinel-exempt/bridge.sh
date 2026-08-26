# ── bridge — seams for the #944 sentinel-only exemption (ADR-097 addendum 3).
ISSUE="123"
REPO_SLUG="teststuffstash/homelab"
PR_NUMBER="123"
CHANGED=$(cat <<'EOF_C'
docs/test.md
agents/coordinator-session.sh
EOF_C
)
TOUCHES_BASE="file://$REPLAY_ROOT/agents"

# gh stub: issue body with a Touches: line; pr diff whose coordinator-session.sh delta is
# sentinel markers ONLY (indented, as extract() trims them) beside an ordinary docs hunk.
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      printf 'Pin the routed-model parse.\n\nTouches: argocd/**, docs/**\n'
      return 0
      ;;
    *"pr diff"*)
      cat <<'EOF_D'
diff --git a/docs/test.md b/docs/test.md
index 1111111..2222222 100644
--- a/docs/test.md
+++ b/docs/test.md
@@ -1,2 +1,3 @@
 heading
+a real docs line
diff --git a/agents/coordinator-session.sh b/agents/coordinator-session.sh
index 3333333..4444444 100644
--- a/agents/coordinator-session.sh
+++ b/agents/coordinator-session.sh
@@ -110,6 +110,8 @@ else
   RESOLVED=""
 fi
+# >>>REPLAY:coordinator-adopt-model>>>
 if [ -n "$RESOLVED" ]; then
   MODEL="${MODEL_MODEL:-$RESOLVED}"
 fi
+# <<<REPLAY:coordinator-adopt-model<<<
EOF_D
      return 0
      ;;
    *)
      echo "gh: unexpected call" >&2
      return 1
      ;;
  esac
}
