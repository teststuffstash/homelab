iv_probe() { printf 'CALL iv_probe %s %s %s\n' "$1" "$2" "$3" >> "$REPLAY_ACTIONS"; return 0; }
set -u
IV_CLAIM_JSON="[]"; resolve_image_volumes 2>&1
printf 'empty-list: [%s%s%s]\n' "$IV_MOUNT" "$IV_VOLUME" "$IV_CARD"
unset IV_CLAIM_JSON; resolve_image_volumes 2>&1
printf 'unset: [%s%s%s]\n' "$IV_MOUNT" "$IV_VOLUME" "$IV_CARD"
IV_CLAIM_JSON='{"not":"a list"}'; resolve_image_volumes 2>&1
printf 'object-not-list: [%s%s%s]\n' "$IV_MOUNT" "$IV_VOLUME" "$IV_CARD"
IV_CLAIM_JSON='not json'; resolve_image_volumes 2>&1
printf 'unparseable: MOUNT[%s] VOLUME[%s] CARD[%s]\n' "$IV_MOUNT" "$IV_VOLUME" "$IV_CARD"
