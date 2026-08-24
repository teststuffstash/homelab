#!/usr/bin/env bash
# asvs-replay — behavioural pin for the ASVS code-class predicate (issue#833).
#
#   bash agents/asvs-replay.sh     # or: devbox run -- bash agents/asvs-replay.sh
#
# WHY THIS EXISTS. The ASVS lens predicate is a `gh pr diff` grep for auth/input/session code
# signatures. Unlike the k8s-prod and helm lenses (which select on paths), the ASVS predicate
# selects on the CODE CONTENT of the diff. This fixture asserts that:
#   1. A diff containing auth imports (jwt, oauth, session, etc.) → ASVS lens is attached
#   2. A diff containing auth function definitions (Login, Authenticate, etc.) → ASVS lens attached
#   3. A diff containing session management calls → ASVS lens attached
#   4. A diff containing new route registrations → ASVS lens attached
#   5. A diff containing none of the above → ASVS lens is NOT attached (quiet miss)
#   6. An empty diff → ASVS lens is NOT attached
#
# WHAT IT RUNS. The `>>>REPLAY:asvs-predicate>>>` block extracted from reviewer-session.sh's PREP
# heredoc. The predicate is tested in isolation with stub diffs.
#
# THE SEAMS:
#   - `gh` is a stub serving canned `pr diff` output
#   - No network, no cluster, no credentials.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${SESSION:-$HERE/reviewer-session.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

command -v jq >/dev/null 2>&1 || { echo "asvs-replay: needs jq (devbox run -- bash $0)"; exit 2; }
[ -f "$SESSION" ] || { echo "asvs-replay: missing $SESSION" >&2; exit 2; }

# ── predicate extraction ────────────────────────────────────────────────────────────────────────
# Extract from SESSION, unescape the heredoc escaping (\$ → $).
extract() {
  awk -v n="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb = 1; saw_open = 1; next }
    line == "# <<<REPLAY:" n "<<<" { inb = 0; saw_close = 1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$2" | sed 's/\\\$/$/g'
}
extract asvs-predicate "$SESSION" > "$TMP/predicate.sh" || {
  echo "asvs-replay: sentinel >>>REPLAY:asvs-predicate>>> missing from $SESSION" >&2
  exit 3
}
[ -s "$TMP/predicate.sh" ] || { echo "asvs-replay: predicate block extracted EMPTY" >&2; exit 3; }

# ── stub gh ─────────────────────────────────────────────────────────────────────────────────────
# Stub `gh pr diff <N>` to return a canned diff based on the DIFF_FIXTURE env var.
cat > "$BIN/gh" <<'STUB'
#!/bin/bash
case "$*" in
  pr\ diff*)
    if [ -f "${DIFF_FIXTURE}" ]; then
      cat "$DIFF_FIXTURE"
      exit 0
    fi
    echo "asvs-replay: DIFF_FIXTURE not set" >&2
    exit 1
    ;;
  *)
    echo "asvs-replay: UNEXPECTED gh call: gh $*" >&2
    exit 9
    ;;
esac
STUB
chmod +x "$BIN/gh"

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
PR=42   # arbitrary PR number for stubs
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout contains: $2" || ok "$1"; }

_go() {   # _go <diff-fixture>
  # The predicate block sets LENSES but doesn't echo it. Source it and capture the value.
  LENSES="" DIFF_FIXTURE="$1" PATH="$BIN:$PATH" \
    bash -c '
      source "$1" 2>/dev/null
      printf "LENSES=%s\n" "$LENSES"
    ' _ "$TMP/predicate.sh" > "$TMP/out.txt" 2> "$TMP/err.txt"
  RC=$?; OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}

printf '\033[1masvs-replay\033[0m — ASVS code-class predicate (issue#833)\n'
printf 'session: %s\n\n' "$SESSION"

# ── 1 ── matching diffs ─────────────────────────────────────────────────────────────────────────
section "1 — matching diffs (auth/input/session code present)"

# 1a: Go JWT auth import
cat > "$TMP/diff_jwt_import.txt" <<'DIFF'
diff --git a/cmd/server.go b/cmd/server.go
index 123..456 100644
--- a/cmd/server.go
+++ b/cmd/server.go
@@ -1,3 +1,5 @@
 package main
 
+import "github.com/golang-jwt/jwt/v5"
+
 func main() {}
DIFF
_go "$TMP/diff_jwt_import.txt"
want "1a: Go JWT import → ASVS attached" "asvs"
want "1a: only ASVS" "LENSES= asvs"
wantnot "1a: no helm" "helm"
wantnot "1a: no k8s-prod" "k8s-prod"

# 1b: Python auth function definition
cat > "$TMP/diff_auth_func.txt" <<'DIFF'
diff --git a/app/auth.py b/app/auth.py
index 123..456 100644
--- a/app/auth.py
+++ b/app/auth.py
@@ -1,3 +1,5 @@
 from flask import request
 
+def login():
+    pass
DIFF
_go "$TMP/diff_auth_func.txt"
want "1b: Python login function → ASVS attached" "asvs"

# 1c: Session management
cat > "$TMP/diff_session.txt" <<'DIFF'
diff --git a/app/handler.go b/app/handler.go
index 123..456 100644
--- a/app/handler.go
+++ b/app/handler.go
@@ -5,3 +5,5 @@
+	session.Save(r, w, sess)
+	return nil
 }
DIFF
_go "$TMP/diff_session.txt"
want "1c: session.Save → ASVS attached" "asvs"

# 1d: New route registration (gin)
cat > "$TMP/diff_gin_route.txt" <<'DIFF'
diff --git a/cmd/router.go b/cmd/router.go
index 123..456 100644
--- a/cmd/router.go
+++ b/cmd/router.go
@@ -1,3 +1,5 @@
+	r := gin.Default()
+	r.GET("/api/orders", handler)
DIFF
_go "$TMP/diff_gin_route.txt"
want "1d: gin route → ASVS attached" "asvs"

# 1e: Python flask route
cat > "$TMP/diff_flask_route.txt" <<'DIFF'
diff --git a/app/routes.py b/app/routes.py
index 123..456 100644
--- a/app/routes.py
+++ b/app/routes.py
@@ -1,3 +1,5 @@
+@app.route('/api/orders', methods=['GET'])
+def list_orders():
+    return jsonify([])
DIFF
_go "$TMP/diff_flask_route.txt"
want "1e: Flask route → ASVS attached" "asvs"

# 1f: OAuth/Passport import (Node/TS)
cat > "$TMP/diff_oauth_import.txt" <<'DIFF'
diff --git a/src/auth.ts b/src/auth.ts
index 123..456 100644
--- a/src/auth.ts
+++ b/src/auth.ts
@@ -1,3 +1,5 @@
+import passport from 'passport';
+
 export function setup() {}
DIFF
_go "$TMP/diff_oauth_import.txt"
want "1f: Passport import → ASVS attached" "asvs"

# 1g: TypeScript @Post decorator route
cat > "$TMP/diff_ts_decorator.txt" <<'DIFF'
diff --git a/src/controller.ts b/src/controller.ts
index 123..456 100644
--- a/src/controller.ts
+++ b/src/controller.ts
@@ -1,3 +1,5 @@
+@Post('/api/users')
+async createUser(@Body() body: CreateUserDto) {}
DIFF
_go "$TMP/diff_ts_decorator.txt"
want "1g: TS @Post decorator → ASVS attached" "asvs"

# 1h: Input validation
cat > "$TMP/diff_validate.txt" <<'DIFF'
diff --git a/app/handler.go b/app/handler.go
index 123..456 100644
--- a/app/handler.go
+++ b/app/handler.go
@@ -1,3 +1,5 @@
+func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
+    if err := r.ParseForm(); err != nil {
+        http.Error(w, "invalid", 400)
+    }
+}
DIFF
_go "$TMP/diff_validate.txt"
want "1h: ParseForm → ASVS attached" "asvs"

# ── 2 ── non-matching diffs ─────────────────────────────────────────────────────────────────────
section "2 — non-matching diffs (no auth/input/session signals)"

# 2a: Config file change
cat > "$TMP/diff_config.txt" <<'DIFF'
diff --git a/config.yaml b/config.yaml
index 123..456 100644
--- a/config.yaml
+++ b/config.yaml
@@ -1,3 +1,5 @@
+debug: true
+timeout: 30
DIFF
_go "$TMP/diff_config.txt"
wantnot "2a: config change → no ASVS" "asvs"

# 2b: Go utility function (no auth signals)
cat > "$TMP/diff_util.txt" <<'DIFF'
diff --git a/pkg/util/strings.go b/pkg/util/strings.go
index 123..456 100644
--- a/pkg/util/strings.go
+++ b/pkg/util/strings.go
@@ -1,3 +1,5 @@
+func TrimAll(s string) string {
+    return strings.TrimSpace(s)
+}
DIFF
_go "$TMP/diff_util.txt"
wantnot "2b: utility function → no ASVS" "asvs"


# 2c: Kubernetes manifest
cat > "$TMP/diff_manifest.txt" <<'DIFF'
diff --git a/argocd/resources/app.yaml b/argocd/resources/app.yaml
index 123..456 100644
--- a/argocd/resources/app.yaml
+++ b/argocd/resources/app.yaml
@@ -1,3 +1,5 @@
+kind: Deployment
+metadata:
+  name: app
DIFF
_go "$TMP/diff_manifest.txt"
wantnot "2c: manifest change → no ASVS" "asvs"


# 2d: Empty diff
: > "$TMP/diff_empty.txt"
_go "$TMP/diff_empty.txt"
wantnot "2d: empty diff → no ASVS" "asvs"


# ── 3 ── edge cases ────────────────────────────────────────────────────────────────────────────
section "3 — edge cases"

# 3a: Diff with "auth" in a non-import context (e.g., a variable named "auth" or a comment)
cat > "$TMP/diff_auth_comment.txt" <<'DIFF'
diff --git a/README.md b/README.md
index 123..456 100644
--- a/README.md
+++ b/README.md
@@ -1,3 +1,5 @@
+<!-- auth section -->
+This is about authentication.
DIFF
_go "$TMP/diff_auth_comment.txt"
wantnot "3a: natural language 'auth' → no ASVS" "asvs"


# 3b: Adding a health check endpoint (no auth)
cat > "$TMP/diff_health.txt" <<'DIFF'
diff --git a/cmd/server.go b/cmd/server.go
index 123..456 100644
--- a/cmd/server.go
+++ b/cmd/server.go
@@ -1,3 +1,5 @@
+func healthHandler(w http.ResponseWriter, r *http.Request) {
+    w.WriteHeader(http.StatusOK)
+}
DIFF
_go "$TMP/diff_health.txt"
wantnot "3b: health handler → no ASVS" "asvs"


# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe ASVS predicate changed behaviour. If the change was deliberate, update the fixture\n'
  printf 'in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery ASVS predicate case holds.\033[0m\n'