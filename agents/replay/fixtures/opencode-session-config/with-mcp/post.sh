# ── observation point ── not launcher code. OC_SETUP is the observable outcome of the opencode
# session config construction: it is the base64-encoded config write command that reaches the pod
# args. If OC_SETUP is empty, the headless run gets no autoApprove and fails (#792 gap 2).
# Emit the decoded config JSON so the assertion can verify autoApprove and MCP are present.
if [ -n "$OC_SETUP" ]; then
  echo "OC_SETUP: SET"
  # Extract the base64 payload from the setup command and decode it
  _b64="$(printf '%s' "$OC_SETUP" | sed -n "s/^printf '%s' '\([A-Za-z0-9+/=]*\)' | base64 -d > \/tmp\/opencode-session.json; $/\1/p")"
  if [ -n "$_b64" ]; then
    echo "CONFIG_JSON: $(printf '%s' "$_b64" | base64 -d)"
  else
    echo "CONFIG_JSON: (parse failed)"
  fi
else
  echo "OC_SETUP: EMPTY"
fi