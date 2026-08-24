# RETRO-CLI-FLAG-SHAPE leg: invokes resolve-model.sh as a real subprocess through the
# retro-session.sh caller flag shape (line 66):
#   bash resolve-model.sh --role retro --class audit --cell <cell> --fallback <m> --model <m>
#
# This is the explicit-override path: --model sets EXPLICIT_MODEL, which makes the
# script short-circuit before the /route call.  No curl, no proxy contact.
# The cell model rides EXACTLY its configured value — the router cannot collapse
# the A/B experiment axis (the #861 fix this row pins).
CLI_FLAGS="--role retro --class audit --cell claude:opus --fallback opus --model opus"
STUB_CURL="ok"
CURL_RESPONSE=""  # unused — override exits before /route