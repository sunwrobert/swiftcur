#!/usr/bin/env bash
# Records reference outputs from real incur. Needs incur checked out at /tmp/incur with deps installed (bun install).
# Usage: scripts/record-incur.sh Tests/SwiftcurTests/Fixtures/cases/cases2.txt
set -uo pipefail
cd "$(dirname "$0")/.."
CASES=$1
FIX=Tests/SwiftcurTests/Fixtures/incur
WORK=$(mktemp -d)
cp Tests/SwiftcurTests/Fixtures/demo.ts "$WORK/demo.ts"
sed -i '' 's#/tmp/incur/src/index.ts#/tmp/incur/src/index.ts#' "$WORK/demo.ts"
printf '#!/bin/sh\nexec bun %s/demo.ts "$@"\n' "$WORK" > "$WORK/demo"; chmod +x "$WORK/demo"
BIN="$WORK/demo"
scripts/fixture-env.sh "$WORK"
while IFS='|' read -r name args; do
  [ -z "$name" ] && continue
  scripts/run-case.sh "$WORK" "$BIN" "$args" > "$FIX/$name.txt"
done < "$CASES"
echo "recorded $(grep -c . "$CASES") cases"
