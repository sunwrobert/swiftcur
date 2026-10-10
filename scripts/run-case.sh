#!/usr/bin/env bash
# Runs one case in a working dir. "@tty" runs under a pseudo-terminal; "BIN" marks where the binary goes.
WORK=$1; BIN=$2; ARGS=$3
FIXTURES="$(cd "$(dirname "$0")/.." && pwd)/Tests/SwiftcurTests/Fixtures"
cd "$WORK"
export HOME="$WORK/home" XDG_DATA_HOME="$WORK/home/.local/share"
mkdir -p "$HOME"
if [[ "$ARGS" == @sh* ]]; then
  ARGS=${ARGS#@sh }
  (eval "unset CI COMPLETE; ${ARGS//BIN/$BIN}") 2>&1; echo "exit=$?"
elif [[ "$ARGS" == @stdin:* ]]; then
  ARGS=${ARGS#@stdin:}
  FILE=${ARGS%% *}; ARGS=${ARGS#"$FILE"}
  eval "env -u CI -u COMPLETE $(echo $ARGS | grep -o "DEMO_DIRECT=1") $BIN ${ARGS/DEMO_DIRECT=1/}" < "$FIXTURES/stdin/$FILE" 2>&1; echo "exit=$?"
elif [[ "$ARGS" == @tty* ]]; then
  ARGS=${ARGS#@tty}
  eval "script -q /dev/null env -u CI -u COMPLETE $BIN $ARGS" 2>&1 < /dev/null | tr -d '\r' | sed -e 's/\^D//g' -e $'s/\x08//g'
  echo "exit=${PIPESTATUS[0]}"
elif [[ "$ARGS" == *BIN* ]]; then
  eval "env -u CI ${ARGS//BIN/$BIN}" 2>&1; echo "exit=$?"
else
  eval "env -u CI -u COMPLETE $BIN $ARGS" 2>&1; echo "exit=$?"
fi
