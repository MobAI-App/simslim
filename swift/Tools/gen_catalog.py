#!/usr/bin/env python3
"""Generates the Swift catalog data from the Go source of truth.

    python3 swift/Tools/gen_catalog.py            # rewrite the generated files
    python3 swift/Tools/gen_catalog.py --check    # exit 1 if they are out of date

Reads profiles.go (Categories), service_descriptions.go, features.go (Features)
and profiles_test.go (forbiddenLabels). Standard library only. This is a
developer tool for the transition period: the normal build never runs it, and
it goes away together with the Go tree at cutover.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_CATALOG = ROOT / "swift/Sources/SimSlimKit/Generated/CatalogData.swift"
OUT_FORBIDDEN = ROOT / "swift/Tests/SimSlimKitTests/Generated/ForbiddenLabels.swift"

TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<comment>//[^\n]*)
  | (?P<block>/\*.*?\*/)
  | (?P<string>"(?:[^"\\\n]|\\.)*")
  | (?P<raw>`[^`]*`)
  | (?P<int>\d+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_.]*)
  | (?P<punct>[{}\[\]():,=])
    """,
    re.VERBOSE | re.DOTALL,
)


class Ident(str):
    pass


def tokenize(text):
    """Tokenizes a literal. Stops quietly at the first character that cannot be
    part of one: the parser has finished the literal long before that point."""
    pos, out = 0, []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            break
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment", "block"):
            continue
        val = m.group()
        if kind == "string":
            val = decode_go_string(val)
        elif kind == "raw":
            kind, val = "string", val[1:-1]
        elif kind == "int":
            val = int(val)
        elif kind == "ident":
            val = Ident(val)
        out.append((kind, val))
    return out


def decode_go_string(lit):
    body, out, i = lit[1:-1], [], 0
    simple = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'"}
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        n = body[i + 1]
        if n in simple:
            out.append(simple[n])
            i += 2
        elif n == "u":
            out.append(chr(int(body[i + 2 : i + 6], 16)))
            i += 6
        else:
            raise SystemExit(f"gen_catalog: unsupported escape \\{n} in {lit!r}")
    return "".join(out)


class Parser:
    """A parser for the subset of Go composite literals these files use."""

    def __init__(self, tokens):
        self.t, self.i = tokens, 0

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)

    def take(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def value(self):
        kind, val = self.peek()
        if kind in ("string", "int"):
            self.take()
            return val
        if kind == "punct" and val == "{":
            return self.braces()
        if kind == "punct" and val == "[" or (kind == "ident" and val == "map"):
            # A type prefix such as []string, []Category or map[string]string.
            while self.peek() != ("punct", "{"):
                self.take()
            return self.braces()
        if kind == "ident":
            self.take()
            if self.peek() == ("punct", "{"):
                return self.braces()
            return val
        raise SystemExit(f"gen_catalog: unexpected token {kind} {val!r}")

    def braces(self):
        assert self.take() == ("punct", "{")
        entries = []
        while self.peek() != ("punct", "}"):
            v = self.value()
            if self.peek() == ("punct", ":"):
                self.take()
                entries.append((v, self.value()))
            else:
                entries.append((None, v))
            if self.peek() == ("punct", ","):
                self.take()
        self.take()
        if entries and all(k is not None for k, _ in entries):
            keys = [k for k, _ in entries]
            dupes = {k for k in keys if keys.count(k) > 1}
            if dupes:
                raise SystemExit(f"gen_catalog: duplicate keys in a literal: {sorted(dupes)}")
            return dict(entries)
        if any(k is not None for k, _ in entries):
            raise SystemExit("gen_catalog: mixed keyed and positional entries")
        return [v for _, v in entries]


def parse_var(path, name):
    text = path.read_text()
    m = re.search(r"^var\s+" + re.escape(name) + r"\s*=\s*", text, re.M)
    if not m:
        raise SystemExit(f"gen_catalog: `var {name} =` not found in {path.name}")
    return Parser(tokenize(text[m.end():])).value()


def swift_string(s):
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def label_list(labels, indent):
    pad = " " * indent
    return "[\n" + "".join(f"{pad}  {swift_string(l)},\n" for l in labels) + f"{pad}]"


def render_catalog():
    categories = parse_var(ROOT / "profiles.go", "Categories")
    descriptions = parse_var(ROOT / "service_descriptions.go", "serviceDescriptionByLabel")
    features = parse_var(ROOT / "features.go", "Features")

    header = (
        "// swift-format-ignore-file\n"
        "// Generated by swift/Tools/gen_catalog.py from profiles.go, service_descriptions.go\n"
        "// and features.go. Do not edit by hand; rerun the tool.\n\n"
    )
    out = [header, "let categorySeeds: [CategorySeed] = [\n"]
    for c in categories:
        for key in ("ID", "Name", "Description", "Downside", "ApproxMemoryMB", "Labels"):
            if key not in c:
                raise SystemExit(f"gen_catalog: category {c.get('ID')} lacks {key}")
        out.append("  CategorySeed(\n")
        out.append(f"    id: {swift_string(c['ID'])},\n")
        out.append(f"    name: {swift_string(c['Name'])},\n")
        out.append(f"    description: {swift_string(c['Description'])},\n")
        out.append(f"    downside: {swift_string(c['Downside'])},\n")
        out.append(f"    approxMemoryMB: {int(c['ApproxMemoryMB'])},\n")
        out.append(f"    labels: {label_list(c['Labels'], 4)},\n")
        always = c.get("AlwaysEnabled", [])
        if always:
            out.append("    alwaysEnabled: [\n")
            for a in always:
                out.append(
                    f"      AlwaysEnabledService(label: {swift_string(a['Label'])}, "
                    f"reason: {swift_string(a['Reason'])}),\n"
                )
            out.append("    ]\n")
        else:
            out.append("    alwaysEnabled: []\n")
        out.append("  ),\n")
    out.append("]\n\n")

    out.append("let serviceDescriptionByLabel: [String: String] = [\n")
    for label, desc in descriptions.items():
        out.append(f"  {swift_string(label)}: {swift_string(desc)},\n")
    out.append("]\n\n")

    out.append("let featureList: [Feature] = [\n")
    for f in features:
        out.append(
            f"  Feature(id: {swift_string(f['ID'])}, name: {swift_string(f['Name'])}, "
            f"labels: {label_list(f['Labels'], 2)}),\n"
        )
    out.append("]\n")

    counts = (
        f"{len(categories)} categories, "
        f"{sum(len(c['Labels']) for c in categories)} category labels, "
        f"{len(descriptions)} descriptions, {len(features)} features"
    )
    return "".join(out), counts


def render_forbidden():
    labels = parse_var(ROOT / "profiles_test.go", "forbiddenLabels")
    body = "".join(f"  {swift_string(l)},\n" for l in labels)
    return (
        "// swift-format-ignore-file\n"
        "// Generated by swift/Tools/gen_catalog.py from profiles_test.go. Do not edit by hand.\n\n"
        "/// Daemons that wedge a simulator when disabled; none may ever be managed.\n"
        f"let forbiddenLabels: [String] = [\n{body}]\n"
    )


def main():
    check = "--check" in sys.argv[1:]
    catalog, counts = render_catalog()
    targets = [(OUT_CATALOG, catalog), (OUT_FORBIDDEN, render_forbidden())]
    stale = []
    for path, content in targets:
        current = path.read_text() if path.exists() else None
        if current != content:
            stale.append(path)
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
    if check:
        if stale:
            print("gen_catalog: out of date: " + ", ".join(str(p.relative_to(ROOT)) for p in stale))
            sys.exit(1)
        print(f"gen_catalog: up to date ({counts})")
    else:
        print(f"gen_catalog: wrote {len(targets)} files ({counts})")


if __name__ == "__main__":
    main()
