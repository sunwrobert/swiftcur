#!/usr/bin/env python3
"""Normalizes a JSON-RPC session for comparison: one response per line, sorted by id, keys sorted."""
import json, sys
lines, tail = [], []
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    try:
        lines.append(json.loads(raw))
    except ValueError:
        tail.append(raw)
lines.sort(key=lambda m: (str(type(m.get("id"))), m.get("id") or 0))
for message in lines:
    print(json.dumps(message, sort_keys=True))
for raw in tail:
    print(raw)
