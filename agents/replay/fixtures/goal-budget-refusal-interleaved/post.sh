# ── observation point ── not launcher code. In agent-session.sh the statement after this block is
# the `elif [ "$GB_VERDICT" = "within" ]` arm and, past the whole pre-flight, the dispatch itself.
# This line stands in for "execution continued"; its ABSENCE from the action stream is the assertion
# that the refusal still exits non-zero, and diff asserts absences for free.
echo "REACHED: the dispatch continued past the pre-flight"
