# ── observation point ── not scan code. block:fu146-resumable-match resolves $uworkbranch from the
# repo-qualified $resumable_branches key; this part is what makes that resolution observable in the
# action stream, so the assertion lives in the fixture instead of in the live dispatch loop.
printf '  RESOLVED: %s#%s \xE2\x86\x92%s\n' "$urepo" "${uitem#issue-}" "$uworkbranch"