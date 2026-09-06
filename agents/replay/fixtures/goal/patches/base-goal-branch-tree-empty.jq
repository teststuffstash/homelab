# base-goal-branch-tree-empty — the ORDINARY shape at the same tree-empty moment: goal #29
# declares `Base: goal/29-p0-slice`, so its value lands in an assembly PR and the assembly-PR key
# still owns its transition. The control row for homelab#1450: the new tree-empty key must not
# touch a `goal/**` goal, which keeps trigger (b) as its deadlock backstop and leaves IL-T18's
# original key the only writer of `goal/post-launch` for it.
map(if .number == 29 then .body += "Base: goal/29-p0-slice\n" else . end)
