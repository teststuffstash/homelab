# The catch-all's own case, kept so the fix cannot widen it into a silent accept: an unknown flag
# still refuses with `unknown arg`, exit 2, before pre-flight.
set -- --bogus-flag
