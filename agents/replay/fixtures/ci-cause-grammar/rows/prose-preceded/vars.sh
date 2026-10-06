# The #1350 anchor belt: a marker preceded by prose on an earlier line. re.MULTILINE makes `^`
# match the marker's own line start; the capture must still name the whole step.
MARKER="$(printf 'Reran and passed after the infra fix.\nci-cause: ci/manifest-lint class=environment basis=observed\n\nThe second run was clean.')"
