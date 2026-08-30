# oracle retro r4 — brief (fixture stand-in)

A short stand-in for the assembled retro brief. It exists because the clause sizes the key from
THIS file (`--issue-file "$BRIEF"`); its content is irrelevant, its existence is not — a missing
brief would make the estimator read stdin and the fixture would hang rather than fail.

Rank the worst-K ledger slice, deep-dive the top K, and emit the report between the
BEGIN-RETRO-REPORT / END-RETRO-REPORT markers.