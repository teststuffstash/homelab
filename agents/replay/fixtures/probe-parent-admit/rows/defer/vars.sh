# row defer — the gateway defers: the tick defers as the subscription latch defers it (exit 0, the
# next cron tick retries); claude never runs, nothing to release.
GW_REPLY_BODY='{"decision":"defer","reason":"subscription-sessions-full","retry_after_s":120}'
