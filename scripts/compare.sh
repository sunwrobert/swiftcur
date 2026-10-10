#!/usr/bin/env bash
# Runs the Swift demo through every case in scripts/cases*.txt and diffs against incur's recorded output.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build --product Demo -c release >/dev/null 2>&1 || { swift build --product Demo -c release 2>&1 | grep error: | head; exit 1; }
WORK=$(mktemp -d)
cp "$(swift build --product Demo -c release --show-bin-path)/Demo" "$WORK/demo"
BIN="$WORK/demo"
scripts/fixture-env.sh "$WORK"
FIX=Tests/SwiftcurTests/Fixtures/incur
normalize() { sed -E -e 's/[0-9]+ms/Nms/g' -e 's#/(private/)?var/folders/[^ "]*/T/tmp\.[A-Za-z0-9]+#WORK#g' -e "s#${WORK}#WORK#g" -e 's/_swiftcur_complete_/_incur_complete_/g'; }
pass=0; fail=0
for cases in Tests/SwiftcurTests/Fixtures/cases/*.txt; do
  while IFS='|' read -r name args; do
    [ -z "$name" ] && continue
    post=cat; [[ "$args" == @stdin:* ]] && post=scripts/normalize-jsonrpc.py
    actual=$(scripts/run-case.sh "$WORK" "$BIN" "$args" | normalize | $post)
    expected=$(normalize < "$FIX/$name.txt" | $post)
    if [ "$actual" == "$expected" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); echo "--- FAIL $name ($args)"
      diff <(echo "$expected") <(echo "$actual") | head -"${DIFF_LINES:-10}"
    fi
  done < "$cases"
done
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
