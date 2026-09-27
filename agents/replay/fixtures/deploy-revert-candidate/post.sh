printf 'CAND=%s\n' "$(printf '%s' "$CAND" | jq -c '{number, sha: .mergeCommit.oid}')"
