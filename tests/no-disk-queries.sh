#!/usr/bin/env bash
# Enforces the disk-sleep invariant from spec section 51.
#
# Current Unraid API versions can spin up sleeping HDDs when asked for
# per-disk or temperature data. Everything in Api.js runs on a background
# timer, so none of it may ever ask for those. Disk details stay strictly
# user-initiated, behind the confirmation dialog in Panel.qml.
#
# Run from the repo root:  ./tests/no-disk-queries.sh
set -uo pipefail

cd "$(dirname "$0")/.."

API_FILE="Api.js"
status=0

if [[ ! -f $API_FILE ]]; then
  echo "FAIL: $API_FILE not found — are you running this from the repo root?" >&2
  exit 1
fi

# Only the query constants matter; comments in this file legitimately
# mention the forbidden paths while explaining why they're forbidden.
queries=$(grep -E '^var QUERY_' -A 4 "$API_FILE" | grep -v '^\s*//')

check() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" <<<"$queries"; then
    echo "FAIL: a polled query requests $label — this can wake sleeping disks (spec section 51)" >&2
    status=1
  else
    echo "ok: no polled query requests $label"
  fi
}

check '\bdisks\b'          "per-disk data (\`disks\`)"
check '\btemperature\b'    "temperatures (\`metrics { temperature }\`)"
check '\bsmart\b|\bSmart\b' "SMART data"

# The queries must also stay in separate operations per resource root
# (spec section 36): one operation asking for docker AND vms AND array
# means one unavailable subsystem can take the others down with it.
if grep -E '^var QUERY_' "$API_FILE" | grep -q 'docker.*vms\|vms.*docker'; then
  echo "FAIL: docker and vms share one operation — a single outage would break both (spec section 36)" >&2
  status=1
else
  echo "ok: docker and vms are separate operations"
fi

if (( status == 0 )); then
  echo "disk-sleep invariant holds"
fi
exit $status
