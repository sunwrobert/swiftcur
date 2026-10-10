#!/usr/bin/env bash
# Files the fixture cases expect in the working directory.
cat > "$1/demo.json" <<'JSON'
{ "commands": { "greet": { "options": { "times": 2, "loud": true } } } }
JSON
cat > "$1/other.json" <<'JSON'
{ "commands": { "greet": { "options": { "times": 3 } } } }
JSON
