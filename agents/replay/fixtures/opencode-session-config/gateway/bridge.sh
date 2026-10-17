# ── bridge ── the parent fixture's opencode recipe ride, admitted through /sessions. python3 is
# shadowed as a TRIPWIRE: a gateway ride must not look up an OpenRouter pin.
OC_SETUP=""; OC_ENV=""
HARNESS="opencode"
RUN_CMD="printf '%s' 'UkVDSVBF' | base64 -d > /tmp/fix-recipe.yaml; opencode run -m gateway/deepseek-v4-flash 'task message'"
MODEL="opencode-go/deepseek-v4-flash"
GOOSE_MODEL="opencode-go/deepseek-v4-flash"
HERE="/tmp/non-existent-opencode-fixture"
OC_INJECT="1"; PROXY_URL="http://proxy.test:8080"
GW_SESSIONS=1; OPENCODE_MODEL="gateway/deepseek-v4-flash"
python3() { echo "TRIPWIRE: pin lookup on a gateway ride" >&2; exit 9; }
