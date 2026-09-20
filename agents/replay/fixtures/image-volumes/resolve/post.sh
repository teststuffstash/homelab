# ── observation point ── not launcher code. The three fragments are spliced verbatim into the pod
# manifest / env card, so printing them (never a derived fact) is what pins the real text.
resolve_image_volumes 2>&1
printf 'IV_MOUNT:%s\n' "$IV_MOUNT"
printf 'IV_VOLUME:%s\n' "$IV_VOLUME"
printf 'IV_CARD:\n%s' "$IV_CARD"
