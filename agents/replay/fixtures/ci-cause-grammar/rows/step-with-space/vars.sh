# The defect's exact shape (oracle-fleet#632): a real e2e step name containing spaces. Pre-fix
# `(\S+)` captures only `e2e/kind`, then ` class=` fails to line up and the marker is dropped.
MARKER='ci-cause: e2e/kind e2e (chart + image + test Garage) class=content basis=observed'
