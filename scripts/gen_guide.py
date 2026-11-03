#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate the code and output blocks of docs/guide.html from the runnable packages
# under src/examples/guide/. The `check` package runs the three model styles, asserts
# they answer the same requests identically, and prints the agreed answer; this
# script takes the code from the marked regions of those packages, escapes it, and
# writes it between the markers in the page.
#
#   python3 scripts/gen_guide.py            # write docs/guide.html
#   python3 scripts/gen_guide.py --check    # exit 1 if the page is stale

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, "docs", "guide.html")

# Each page slot is filled from one or more marked source regions, concatenated.
REGIONS = {
    "model:annotated": [
        ("src/examples/guide/annotated/models.mbt", "model"),
        ("src/examples/guide/annotated/main.mbt", "accessor"),
    ],
    "model:functional": [("src/examples/guide/functional/main.mbt", "model")],
    "model:class": [("src/examples/guide/class/main.mbt", "model")],
    "ddl-code": [("src/examples/guide/report/report.mbt", "ddl")],
    "query-code": [("src/examples/guide/report/report.mbt", "query")],
    "insert-code": [("src/examples/guide/report/report.mbt", "insert")],
    "diff-code": [("src/examples/guide/report/report.mbt", "diff")],
}

# Each page slot is filled from one `=== name ===` section of the check's output.
SECTIONS = {
    "ddl-out": "ddl",
    "query-out": "query",
    "insert-out": "insert",
    "diff-out": "diff",
}


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8", newline="") as f:
        return f.read()


def region(path, name):
    text = read(path)
    m = re.search(
        r"// --8<-- \[start:%s\]\n(.*?)\n// --8<-- \[end:%s\]" % (name, name),
        text,
        re.S,
    )
    if not m:
        sys.exit("gen_guide: no %s region in %s" % (name, path))
    lines = []
    for line in m.group(1).split("\n"):
        # Documentation comments are part of the API, not of a tutorial snippet.
        if line.strip().startswith("///"):
            continue
        lines.append(line)
    while lines and lines[0].strip() == "":
        lines.pop(0)
    while lines and lines[-1].strip() == "":
        lines.pop()
    return "\n".join(lines)


def escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def run_check():
    r = subprocess.run(
        ["moon", "run", "src/examples/guide/check", "--target", "js"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        sys.stderr.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit("gen_guide: the three styles disagree or the check did not run")
    return r.stdout


def section(output, name):
    m = re.search(r"^=== %s ===\n(.*?)(?=^=== |\Z)" % name, output, re.S | re.M)
    if not m:
        sys.exit("gen_guide: no %s section in the check output" % name)
    return m.group(1).rstrip("\n")


def inject(html, name, content):
    pat = re.compile(
        r"(<!-- guide:%s -->).*?(<!-- /guide:%s -->)"
        % (re.escape(name), re.escape(name)),
        re.S,
    )
    if not pat.search(html):
        sys.exit("gen_guide: no <!-- guide:%s --> marker in the page" % name)
    return pat.sub(lambda m: m.group(1) + content + m.group(2), html, count=1)


def main():
    check = "--check" in sys.argv[1:]
    output = run_check()
    html = read("docs/guide.html")
    for name, parts in REGIONS.items():
        code = "\n\n".join(region(p, n) for p, n in parts)
        html = inject(html, name, escape(code))
    for name, sec in SECTIONS.items():
        html = inject(html, name, escape(section(output, sec)))
    if check:
        if html != read("docs/guide.html"):
            sys.exit(
                "gen_guide: docs/guide.html is stale; run python3 scripts/gen_guide.py",
            )
        print("docs/guide.html is up to date")
    else:
        with open(PAGE, "w", encoding="utf-8", newline="") as f:
            f.write(html)
        print("wrote docs/guide.html")


if __name__ == "__main__":
    main()
