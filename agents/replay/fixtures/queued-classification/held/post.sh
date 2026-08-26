#!/bin/bash
# ── post ── verify the queued-held classification

[ -z "$qclass_item" ] && echo "ERROR: qclass_item not set" >&2 && exit 1
[ "$qclass_item" = "queued-held" ] && echo "RESULT classification=queued-held" || \
  (echo "ERROR: expected qclass_item=queued-held, got $qclass_item" >&2; exit 1)
