#!/usr/bin/env python3
"""Normalizes one simslim output stream for the Go-vs-Swift parity check.

stdin -> stdout. Volatile values (UDIDs, home directory, binary paths, durations,
and with --shape every number) are replaced so that two correct implementations
produce identical text. JSON is re-serialized with sorted keys; JSON lines
(watch --json) are normalized per line. A null array and an empty array are the
same here: the Go encoder prints null where Swift prints [] (a known, harmless
difference). Everything else must match exactly.
"""
import argparse
import json
import os
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--dev", default="", help="UDID of the scratch device, shown as <DEV>")
ap.add_argument("--bin", action="append", default=[], help="binary path to mask")
ap.add_argument("--shape", action="store_true", help="mask every number (live measurements)")
ap.add_argument("--kinds", action="store_true", help="JSON lines: keep only the event names")
args = ap.parse_args()

text = sys.stdin.read()
seen = {}


def uuid_sub(match):
    value = match.group(0).upper()
    if args.dev and value == args.dev.upper():
        return "<DEV>"
    seen.setdefault(value, "<UDID%d>" % (len(seen) + 1))
    return seen[value]


def scrub(s):
    s = re.sub(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", uuid_sub, s)
    for path in args.bin:
        s = s.replace(path, "<simslim>")
    s = s.replace(os.path.expanduser("~"), "~")
    s = re.sub(r"\bsimslim (dev|v?\d[\w.\-+]*)\b", "simslim <version>", s)
    s = re.sub(r"\b\d+(\.\d+)?(ms|µs|s|m|h)\b", "<dur>", s)
    return s


def walk(value):
    if value is None:
        return []
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return "<num>" if args.shape else value
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        return [walk(v) for v in value]
    if isinstance(value, dict):
        return {scrub(k): walk(v) for k, v in value.items()}
    return value


def dump(value):
    return json.dumps(value, sort_keys=True, indent=1, ensure_ascii=False)


try:
    print(dump(walk(json.loads(text))))
except ValueError:
    lines = [l for l in text.splitlines() if l.strip()]
    try:
        events = [json.loads(l) for l in lines]
        if lines and all(isinstance(e, dict) for e in events):
            if args.kinds:
                print("\n".join(str(e.get("event")) for e in events))
            else:
                print("\n".join(dump(walk(e)) for e in events))
            sys.exit(0)
    except ValueError:
        pass
    sys.stdout.write(scrub(text))
