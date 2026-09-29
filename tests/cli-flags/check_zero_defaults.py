#!/usr/bin/env python3
"""Flag a jq or yq alternative (//) whose fallback is true or a non-zero number.

jq and yq take the right side of // when the left side is null OR false, so
'.enableHttpsTrafficOnly // true' turns an explicit false into true, and
'.replicas // 1' turns nothing into 1 but false into 1 as well. That is how the
pre-created preflight read "Secure transfer required: false" as true (Round 12
finding F3, design decision I22). Write the null test out instead:

    if .enableHttpsTrafficOnly == null then true else .enableHttpsTrafficOnly end

'// false', '// 0', '// ""' and '// []' are safe: the fallback is the zero value
the left side would have given. A line may opt out with the comment
"zero-default-ok" when the left side can never be false (explain why next to it).

  check_zero_defaults.py PATH...            exit 1 when a line matches
  check_zero_defaults.py --expect N PATH... exit 1 unless exactly N lines match (self-test)
"""
import argparse
import os
import re
import sys

PATTERN = re.compile(r"//\s*(true|[1-9][0-9]*)(?![\w.])")
SUFFIXES = (".sh", ".yaml", ".yml", ".md", ".py", ".tpl", ".hcl", ".json")
SKIP_DIRS = {"fixtures", ".git", "__pycache__", "source-crds", "schemas", "node_modules", ".work"}
SELF = os.path.abspath(__file__)


def lines(paths):
    for p in paths:
        if os.path.isfile(p):
            files = [p]
        else:
            files = []
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                files += [os.path.join(root, n) for n in sorted(names) if n.endswith(SUFFIXES)]
        for f in files:
            if os.path.abspath(f) == SELF:
                continue
            with open(f, errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    yield f, n, line.rstrip("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect", type=int)
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args()
    hits = []
    for f, n, line in lines(a.paths):
        if "zero-default-ok" in line:
            continue
        for m in PATTERN.finditer(line):
            before = line[:m.start()]
            if before.rstrip().endswith(":") or "http" in before[-8:]:
                continue  # a URL scheme, not an alternative
            hits.append(f"{f}:{n}: '// {m.group(1)}' also replaces an explicit false: test for null instead\n    {line.strip()}")
    if a.expect is not None:
        if len(hits) != a.expect:
            print(f"zero-defaults self-test: expected {a.expect} finding(s), got {len(hits)}")
            print("\n".join(hits))
            return 1
        print(f"zero-defaults self-test passed: {len(hits)} planted finding(s)")
        return 0
    if hits:
        print("\n".join(hits))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
