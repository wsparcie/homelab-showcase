#!/usr/bin/env python3
"""Format image-check.py JSON lines (stdin) as Markdown bullets for the weekly report."""
import json, sys
for line in sys.stdin:
    if not line.strip(): continue
    d = json.loads(line)
    if d.get("error"):
        print(f"- {d['image']}: {d['error']}"); continue
    if not d["update"]: continue
    old = " ".join(x for x in (d.get("pinned_version"), f"({d['built']})" if d.get("built") else "") if x) or "pinned"
    new = " ".join(x for x in (d.get("new_version"), f"({d['new_built']})" if d.get("new_built") else "") if x) or "newer image"
    print(f"- **{d['image']}**: {old} -> {new}")
