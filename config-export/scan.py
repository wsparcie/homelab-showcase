#!/usr/bin/env python3
"""Second gate after redact.py: report anything that still looks like a secret. Exit 1 if findings.

Checks: the redact.py patterns must no longer match, plus high-entropy tokens (>= 24 chars, Shannon entropy
>= 4.2 bits/char) that are not obviously harmless (image digests, UUIDs, hashes in lock files, public SSH keys).
Prints file:line and a masked preview only, never the value.
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from redact import PATTERNS, R, TOKEN, LINE_OK, suspicious  # noqa: E402

def mask(s):
    return s[:4] + "…" + f"({len(s)} chars)"


def main(root):
    findings = []
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            try:
                lines = open(p, encoding="utf-8").read().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            text = "\n".join(lines)
            for rx, _ in PATTERNS:
                for m in rx.finditer(text):
                    if R not in m.group(0):
                        ln = text[:m.start()].count("\n") + 1
                        findings.append((rel, ln, "pattern", mask(m.group(0))))
            for i, line in enumerate(lines, 1):
                if LINE_OK.search(line):
                    continue
                for tok in TOKEN.findall(line):
                    if suspicious(tok):
                        findings.append((rel, i, "entropy", mask(tok)))
    for rel, ln, kind, prev in findings:
        print(f"  {rel}:{ln}  {kind}  {prev}")
    print(f"scan: {len(findings)} findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
