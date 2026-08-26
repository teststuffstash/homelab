#!/bin/bash
# ── post ── verify the queued-ready classification

[ -z "$qclass_item" ] && echo "ERROR: qclass_item not set" >&2 && exit 1
[ "$qclass_item" = "queued-ready" ] && echo "RESULT classification=queued-ready" || \
  (echo "ERROR: expected qclass_item=queued-ready, got $qclass_item" >&2; exit 1)
