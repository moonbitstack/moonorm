#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate docs/api.html from the moonorm packages' pkg.generated.mbti files.
# Run `moon info --target js` first to (re)produce the .mbti files.
#
#   python3 scripts/gen_api.py            # write docs/api.html
#   python3 scripts/gen_api.py --check     # exit 1 if docs/api.html is stale

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (mbti path relative to repo root, full package name, display label, anchor)
PACKAGES = [
    ("src/pkg.generated.mbti", "moonbitstack/moonorm", "moonorm", "moonorm"),
    ("src/schema/pkg.generated.mbti", "moonbitstack/moonorm/schema", "schema", "schema"),
    ("src/query/pkg.generated.mbti", "moonbitstack/moonorm/query", "query", "query"),
    ("src/session/pkg.generated.mbti", "moonbitstack/moonorm/session", "session", "session"),
    ("src/migrate/pkg.generated.mbti", "moonbitstack/moonorm/migrate", "migrate", "migrate"),
]

TYPE_KINDS = {"struct", "enum", "trait", "suberror", "type"}
DECL_RE = re.compile(r"^\s*pub(?:\([^)]*\))?\s+(struct|enum|trait|suberror|type|fn|const|extern)\b")

SKIP_PREFIXES = (
    "//", "package", "import", "derive(", "pub impl", "pub extend",
    ")", "}",
)


def _count(text, opens, closes):
    return text.count(opens) - text.count(closes)


def parse_mbti(path):
    types, fns = [], []
    buf = None
    brace = paren = 0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            s = line.strip()
            if buf is None:
                if not s or s.startswith(SKIP_PREFIXES):
                    continue
                m = DECL_RE.match(line)
                if not m:
                    continue
                buf = line
                brace = _count(line, "{", "}")
                paren = _count(line, "(", ")")
                if brace <= 0 and paren <= 0:
                    _flush(buf, m.group(1), types, fns)
                    buf = None
            else:
                buf += "\n" + line
                brace += _count(line, "{", "}")
                paren += _count(line, "(", ")")
                if brace <= 0 and paren <= 0:
                    m = DECL_RE.match(buf)
                    kind = m.group(1) if m else "fn"
                    _flush(buf, kind, types, fns)
                    buf = None
    return types, fns


def _flush(sig, kind, types, fns):
    target = types if kind in TYPE_KINDS else fns
    target.append(_esc(sig.strip()))


def _esc(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def section(pkg_name, label, anchor, types, fns):
    out = []
    out.append(f'<section class="section" id="{anchor}">')
    out.append(f'<p class="folio">{_esc(pkg_name)}</p>')
    out.append(f"<h2>{_esc(label)}</h2>")
    if types:
        out.append("<h3>Types</h3>")
        for t in types:
            out.append(f'<pre class="signature">{t}</pre>')
    if fns:
        out.append("<h3>Functions &amp; methods</h3>")
        for f in fns:
            out.append(f'<pre class="signature">{f}</pre>')
    out.append("</section>")
    return "\n".join(out)


def build():
    sections = []
    nav = []
    for rel, full, label, anchor in PACKAGES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            sys.stderr.write(f"warn: missing {rel}, skipping\n")
            continue
        types, fns = parse_mbti(path)
        sections.append(section(full, label, anchor, types, fns))
        nav.append(f'<a href="#{anchor}" aria-current="page">{label}</a>')
    return "\n".join(nav), "\n".join(sections)


HTML = """<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>API · moonorm</title>
  <meta name="description" content="moonorm public API reference, generated from pkg.generated.mbti and /// docs.">
  <link rel="icon" type="image/svg+xml" href="favicon.svg">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Newsreader:opsz,wght@6..72,500;6..72,600&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="assets/css/tokens.css">
  <link rel="stylesheet" href="assets/css/moonorm.css">
</head>
<body>
  <header class="topbar">
    <a class="brand" href="index.html" style="border:0">
      <svg class="glyph" viewBox="0 0 32 32" fill="none" aria-hidden="true"><line x1="16" y1="2" x2="16" y2="30" stroke="currentColor" stroke-width="2"/><circle cx="16" cy="16" r="4" fill="var(--mapped)"/></svg>
      moonorm
    </a>
    <nav class="nav">
      <a href="index.html">Home</a>
      <a href="guide.html">Guide</a>
      <a href="api.html" aria-current="page">API</a>
      <a href="showcase.html">Showcase</a>
      <a href="https://github.com/moonbitstack/moonorm" rel="noopener">GitHub</a>
    </nav>
    <button class="theme-toggle" id="theme-toggle" onclick="toggleTheme()">day</button>
  </header>

  <main class="wrap">
    <div class="doc-grid">
      <aside class="side">
        <div class="grp">Packages</div>
        {NAV}
      </aside>
      <div>
        <section class="hero" style="padding-top:var(--s5)">
          <p class="folio">API</p>
          <h1 style="font-size:clamp(30px,4vw,46px)">Public surface</h1>
          <p class="lede">Generated from <code class="inline">pkg.generated.mbti</code> via <code class="inline">moon info</code>. This page is rebuilt by the docs workflow, so it never drifts from the code.</p>
        </section>
{SECTIONS}
        <div class="cta">
          <a class="btn primary" href="guide.html">Read the guide</a>
          <a class="btn" href="index.html">Back to the seam</a>
        </div>
      </div>
    </div>
  </main>

  <footer class="foot">
    <span>moonorm · Apache-2.0 · MoonBit ORM &amp; SQL toolkit</span>
    <span><a href="https://github.com/moonbitstack/moonorm" rel="noopener">github.com/moonbitstack/moonorm</a></span>
  </footer>

  <script src="assets/js/theme.js"></script>
</body>
</html>
"""


def main():
    check = "--check" in sys.argv
    nav, sections = build()
    html = HTML.replace("{NAV}", nav).replace("{SECTIONS}", sections)
    out_path = os.path.join(ROOT, "docs", "api.html")
    if check:
        if not os.path.exists(out_path):
            sys.stderr.write("docs/api.html missing\n")
            return 1
        with open(out_path, encoding="utf-8") as fh:
            existing = fh.read()
        # normalise trailing whitespace / final newline differences
        if existing.rstrip() != html.rstrip():
            sys.stderr.write("docs/api.html is stale; run scripts/gen_api.py\n")
            return 1
        return 0
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html)
    sys.stderr.write(f"wrote {out_path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
