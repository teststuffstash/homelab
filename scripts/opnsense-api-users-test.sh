#!/usr/bin/env bash
# Self-test for scripts/opnsense-api-users.sh's storage contract: whatever the users play minted
# into the sink reaches the wallet EVEN WHEN THE PLAY FAILS after the mint, and the script then exits
# with the play's code (a minted secret is shown once; losing it strands a key on a node nobody holds).
#
#   bash scripts/opnsense-api-users-test.sh        (devbox run opnsense-users-self-test runs it)
#
# Seams — no production seam was added: the script under test is COPIED into a throwaway tree whose
# scripts/opnsense-playbook.sh is a stub (it cd's to its own dirname/.., so the stub is what it runs),
# `devbox` is a PATH stub (keepassxc-cli -> a directory of entry files, yq -> the real yq,
# infisical-secret -> a log), and HOME points at a dir holding an empty "wallet" file. NOT stubbed
# away, so NOT covered here: the real keepassxc-cli argument shapes, the real play.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
YQ="$(command -v yq || true)"
[ -n "$YQ" ] || { echo "opnsense-api-users-test: needs yq on PATH (run under devbox)" >&2; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0; n=0
check() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

mkdir -p "$T/repo/scripts" "$T/repo/ansible/group_vars" "$T/home/.claude/homelab-keepass" "$T/bin"
cp "$SRC/scripts/opnsense-api-users.sh" "$T/repo/scripts/"
cp "$SRC/ansible/group_vars/opnsense.yml" "$T/repo/ansible/group_vars/"
: > "$T/home/.claude/homelab-keepass/homelab.kdbx"

# The play stub: writes STUB_MINT's pairs into the sink the script passed, records the wallet map
# it was handed, exits STUB_RC (a failure AFTER the sink write — the install / end-state checks).
cat > "$T/repo/scripts/opnsense-playbook.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sink=''; walletf=''
while [ $# -gt 0 ]; do
  case "$1" in
    -e) case "$2" in opnsense_users_key_sink=*) sink="${2#*=}" ;; @*) walletf="${2#@}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ "${OPN_AS_ROOT:-}" = 1 ] || { echo "stub: not run as root" >&2; exit 9; }
[ -z "$walletf" ] || cp "$walletf" "$STUB_LOG.wallet-map"
for u in ${STUB_MINT:-}; do printf 'KEY-%s' "$u" > "$sink/$u.key"; printf 'SECRET-%s' "$u" > "$sink/$u.secret"; done
exit "${STUB_RC:-0}"
EOF
# devbox stub: `devbox run [--quiet] -- <tool> …` and `devbox run infisical-secret …`.
cat > "$T/bin/devbox" <<EOF
#!/usr/bin/env bash
set -euo pipefail
W="\$STUB_WALLET"
shift   # run
while [ "\${1:-}" = --quiet ] || [ "\${1:-}" = -- ]; do shift; done
tool="\$1"; shift
case "\$tool" in
  yq) exec "$YQ" "\$@" ;;
  infisical-secret) echo "\$*" >> "\$STUB_LOG.infisical" ;;
  keepassxc-cli)
    sub="\$1"; entry="\${!#}"
    case "\$sub" in
      show) [ -f "\$W/\$entry" ] || exit 1; case " \$* " in *" -a Password "*) cat "\$W/\$entry" ;; esac ;;
      add|edit) cat > "\$W/\$entry" ;;
      *) echo "devbox stub: keepassxc-cli \$sub" >&2; exit 9 ;;
    esac ;;
  *) echo "devbox stub: \$tool" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/devbox" "$T/repo/scripts/opnsense-playbook.sh"

# shellcheck disable=SC2034  # RC/OUT are read inside the check() eval strings
run() { # run <case> <STUB_MINT> <STUB_RC> -> RC, OUT; fresh wallet unless KEEP_WALLET=1
  local c="$1"
  [ "${KEEP_WALLET:-0}" = 1 ] || { rm -rf "$T/wallet"; mkdir -p "$T/wallet"; }
  set +e
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" STUB_WALLET="$T/wallet" STUB_LOG="$T/$c" \
         STUB_MINT="$2" STUB_RC="$3" bash "$T/repo/scripts/opnsense-api-users.sh" 2>&1)"; RC=$?
  set -e
}
w() { cat "$T/wallet/$1" 2>/dev/null; }

# 1. The defect: the play mints `firmware` on the first node, then fails (rc 2) installing it on the
#    second. Contract: the pair is in the wallet anyway, and the script exits 2, not 0.
run fail-after-mint firmware 2
check "fail after mint: exits with the play's code (2)" '[ "$RC" = 2 ]'
check "fail after mint: wallet key stored" '[ "$(w opnsense-firmware-api-key)" = KEY-firmware ]'
check "fail after mint: wallet secret stored" '[ "$(w opnsense-firmware-api-secret)" = SECRET-firmware ]'
check "fail after mint: says it failed" 'grep -q "FAILED (rc=2)" <<< "$OUT"'

# 2. The re-run: the wallet now holds the pair, so its public half reaches the play's wallet map
#    (the plan then installs it on the node that lacks it — opn_user_keys.py's "rebuilt" case).
KEEP_WALLET=1 run rerun "" 0
check "rerun: exits 0" '[ "$RC" = 0 ]'
check "rerun: wallet map carries the stored key" 'grep -q "\"firmware\": \"KEY-firmware\"" "$T/rerun.wallet-map"'
check "rerun: nothing minted, wallet unchanged" 'grep -q "done: 0 key pair" <<< "$OUT" && [ "$(w opnsense-firmware-api-secret)" = SECRET-firmware ]'

# 3. A clean mint: stored, exit 0; backup-puller also goes to Infisical.
run clean "backup-puller" 0
check "clean mint: exits 0 and stores" '[ "$RC" = 0 ] && [ "$(w opnsense-backup-puller-api-secret)" = SECRET-backup-puller ]'
check "clean mint: backup-puller to infisical" 'grep -q "OPNSENSE_BACKUP_PULLER_API_SECRET=SECRET-backup-puller" "$T/clean.infisical"'

# 4. A failure with nothing minted (e.g. the plan refused): exit code kept, wallet untouched.
run refused "" 2
check "refused: exits 2, wallet empty" '[ "$RC" = 2 ] && [ -z "$(ls "$T/wallet")" ]'

echo "opnsense-api-users-test: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
