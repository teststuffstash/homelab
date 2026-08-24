# RETRO-EXPLICIT-MODEL leg: role=retro, --model set explicitly (the cell model as
# explicit override, matching the retro-session.sh fix in #861).  The cell model
# rides EXACTLY its configured value — the router cannot collapse the A/B axis.
# The CURL_RESPONSE shows what the router WOULD have dispatched, but the override
# exits before /route — no curl, no proxy contact.
ROLE="retro"
FALLBACK="sonnet"
CLASS="audit"
CELL="claude:opus"
OVERRIDE="opus"
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"tencent/hy3"}'