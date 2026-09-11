#!/usr/bin/env bash
# Enforces the disk-sleep invariant from spec section 51.
#
# What actually wakes a sleeping HDD is the Unraid API's DisksService: the
# top-level `disks`/`disk` root shells out to `smartctl` and to
# systeminformation's `diskLayout()`, so the `Disk` type's `temperature` and
# `smartStatus` cost a spin-up. Everything in Api.js runs on a background
# timer, so none of it may ever go near those.
#
# `array { parities/disks/caches }` is NOT in that category and is allowed.
# Those resolve out of the emhttp state the API already holds in memory
# (unraid/api: api/src/core/modules/array/get-array-data.ts reads
# `state.emhttp.disks`, parsed by api/src/store/state-parsers/slots.ts from
# /var/local/emhttp/disks.ini). Every ArrayDisk field — `temp` and
# `isSpinning` included — comes from that file, so the query issues no device
# I/O; a parked drive reports `temp: null` instead of being woken to answer.
# The earlier blanket ban on the word `disks` was wider than the hazard and
# cost the plugin its whole Storage disk list.
#
# The operations are collected by *evaluating* Api.js rather than by grepping
# it. An earlier grep-only version read the raw string literals, which since
# the disk query is assembled from fragments (`"disks { " + DISK_FIELDS`)
# meant it judged `"disks { "` on its own, with the `array {` that makes it
# legal sitting in a different literal. Evaluating checks the text that is
# actually sent, and covers the operations built inside functions too.
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

# Every operation the plugin can send: the QUERY_* constants, plus each
# query/mutation builder called with a stand-in argument. `new Function`
# can't enumerate its own locals, so the names come from the file's own
# declarations.
names=$(grep -oE '^(var|function) +[A-Za-z_$][A-Za-z0-9_$]*' "$API_FILE" \
  | awk '{print $2}' | sort -u)

queries=$(node -e '
  const fs = require("fs")
  const src = fs.readFileSync(process.argv[1], "utf8").replace(/^\s*\.pragma\s+library\s*/, "")
  const names = process.argv[2].split("\n").filter(Boolean)
  const collect = new Function("__names", src + `
    const out = []
    for (const name of __names) {
      let value
      try { value = eval(name) } catch (e) { continue }
      if (typeof value === "string") out.push(name + ": " + value)
      else if (typeof value === "function" && /^(query|mutation)/.test(name)) {
        try { out.push(name + ": " + value("probe-id", 100)) } catch (e) {}
      }
    }
    return out.join(String.fromCharCode(10))
  `)
  process.stdout.write(collect(names))
' "$API_FILE" "$names")

if [[ -z $queries ]]; then
  echo "FAIL: no operations could be extracted from $API_FILE" >&2
  exit 1
fi

# Only the operations, not the helper strings that merely mention a field.
queries=$(grep -E '\{' <<<"$queries")

check() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" <<<"$queries"; then
    echo "FAIL: a polled query requests $label — this can wake sleeping disks (spec section 51)" >&2
    grep -E "$pattern" <<<"$queries" | sed 's/^/       /' >&2
    status=1
  else
    echo "ok: no polled query requests $label"
  fi
}

# The `disks`/`disk` query root, i.e. the operation's *first* selection.
check ': *(mutation )?\{ *disks?\b' "the top-level \`disks\` root (SMART-backed)"
check '\btemperature\b'             "\`Disk.temperature\` (smartctl)"
check '\bsmart|\bSmart'             "SMART data"

# And the allowance stays narrow: `disks` is only ever legal as a field of
# the array root, so an operation naming it must also select one.
while IFS= read -r operation; do
  [[ -z $operation ]] && continue
  if grep -q '\bdisks\b' <<<"$operation" && ! grep -q 'array *{' <<<"$operation"; then
    echo "FAIL: \`disks\` appears outside an \`array { … }\` selection:" >&2
    echo "       $operation" >&2
    status=1
  fi
done <<<"$queries"

# The queries must also stay in separate operations per resource root
# (spec section 36): one operation asking for docker AND vms AND array
# means one unavailable subsystem can take the others down with it.
if grep -q 'docker.*vms\|vms.*docker' <<<"$queries"; then
  echo "FAIL: docker and vms share one operation — a single outage would break both (spec section 36)" >&2
  status=1
else
  echo "ok: docker and vms are separate operations"
fi

if (( status == 0 )); then
  echo "disk-sleep invariant holds"
fi
exit $status
