#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate docs/api.html from the moonorm packages. The public surface
# comes from `pkg.generated.mbti` (so nothing public can be missed, type
# parameters included), the prose from the `///` comments in the sources, which
# the mbti format does not carry, and each page's shell from the
# `api.template.html` beside it.
#
#   moon info --target js                  # in the root
#   python3 scripts/gen_api.py            # write the page
#   python3 scripts/gen_api.py --check    # exit 1 if the page is stale

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (package dir, full package name, display label, anchor)
# Each site: the page it writes, the shell it fills, the class its package
# labels take, and the packages it lists in order.
SITES = [
    {
        "out": "docs/api.html",
        "template": "docs/api.template.html",
        "eyebrow": "eyebrow",
        "packages": [
            ("src", "moonbitstack/moonorm", "moonorm", "moonorm"),
            ("src/schema", "moonbitstack/moonorm/schema", "schema", "schema"),
            ("src/query", "moonbitstack/moonorm/query", "query", "query"),
            ("src/session", "moonbitstack/moonorm/session", "session", "session"),
            ("src/migrate", "moonbitstack/moonorm/migrate", "migrate", "migrate"),
        ],
    },
]

TYPE_KINDS = {"struct", "enum", "trait", "suberror", "type"}

EXTEND_RE = re.compile(r"^pub extend ([A-Za-z_]\w*) with ([@\w.]+)::\{([^}]*)\}", re.M)
PLUMBING = {"Eq", "Debug", "Show", "Hash", "Compare", "Default"}

# Members a `derive(...)` synthesises carry no documentation and are not part of
# the surface a reader looks up here; they are dropped unless someone wrote a
# `///` for them by hand.
DERIVED = {"equal", "not_equal", "to_repr", "to_string", "output"}

# The site's wording rule forbids naming other implementations, while the source
# `///` docs explain by analogy ("matching SQLAlchemy's column()"). Foreign
# clauses are removed here, at the clause level, so the explanation survives.
FOREIGN = (
    "SQLAlchemy", "SQLModel", "Diesel", "Alembic", "MyBatis", "jOOQ", "GORM",
    "Django", "SQLx", "ActiveRecord", "Hibernate", "Ecto", "Prisma", "TypeORM",
    "Kysely", "Go's", "Rust's", "Serde",
)
SKIP_PREFIXES = ("//", "package", "import", "derive(", "pub impl", "pub extend", ")", "}")

DECL_RE = re.compile(
    r"^\s*pub(?:\([^)]*\))?\s+"
    r"(struct|enum|trait|suberror|type|fn|const|let)\s*"
    r"(?:\[[^\]]*\]\s*)?"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)


def _count(text, opens, closes):
    return text.count(opens) - text.count(closes)


def _esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def parse_mbti(path):
    """Every public declaration in the package, as (kind, emit_key, signature)."""
    out = []
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
                    out.append((m.group(1), _key(line), buf.strip()))
                    buf = None
            else:
                buf += "\n" + line
                brace += _count(line, "{", "}")
                paren += _count(line, "(", ")")
                if brace <= 0 and paren <= 0:
                    m = DECL_RE.match(buf)
                    out.append((m.group(1) if m else "fn", _key(buf), buf.strip()))
                    buf = None
    return out


def _key(decl):
    m = DECL_RE.match(decl)
    return m.group(2) if m else ""


def parse_docs(pkg_dir):
    """key -> list of doc lines, harvested from the `///` blocks in the sources."""
    docs = {}
    paths = sorted(glob.glob(os.path.join(pkg_dir, "**", "*.mbt"), recursive=True))
    for path in paths:
        if path.endswith("_test.mbt") or path.endswith("_wbtest.mbt"):
            continue
        pending = []
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
        for m in EXTEND_RE.finditer("".join(lines)):
            if m.group(2) not in PLUMBING:
                for method in (s.strip() for s in m.group(3).split(",")):
                    docs.setdefault(f"{m.group(1)}::{method}", f"`{m.group(2)}`'s `{method}`, callable on the value directly.")
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                s = line.strip()
                if s.startswith("///"):
                    text = s[3:].strip()
                    if text != "|":
                        pending.append(text)
                    continue
                if not s:
                    continue
                if pending and DECL_RE.match(line):
                    body = "\n".join(pending).strip()
                    if body:
                        docs.setdefault(_key(line), body)
                pending = []
    return docs


def _drop_foreign(text):
    if not any(name in text for name in FOREIGN):
        return text
    kept_sentences = []
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if not any(name in sentence for name in FOREIGN):
            kept_sentences.append(sentence)
            continue
        parts = re.split(r"\s+[\u2014-]\s+|,\s+", sentence)
        kept = [p for p in parts if not any(name in p for name in FOREIGN)]
        rebuilt = ", ".join(p.strip() for p in kept if p.strip())
        if rebuilt and not any(name in rebuilt for name in FOREIGN):
            if not rebuilt.endswith((".", "!", "?")):
                rebuilt += "."
            kept_sentences.append(rebuilt[0].upper() + rebuilt[1:] if rebuilt else rebuilt)
    out = " ".join(kept_sentences).strip()
    return re.sub(r"\s+([,.;])", r"\1", out)


def render_doc(text):
    """`///` prose -> paragraphs with inline code."""
    text = _drop_foreign(text or "")
    if not text:
        return ""
    chunks = []
    for para in re.split(r"\n\s*\n", text):
        para = " ".join(x.strip() for x in para.splitlines() if x.strip())
        if not para:
            continue
        para = _esc(para)
        para = re.sub(r"`([^`]+)`", r'<code class="inline">\1</code>', para)
        chunks.append(f"<p>{para}</p>")
    return "".join(chunks)


def render_entry(kind, sig, doc):
    body = render_doc(doc)
    out = ['<div class="entry">']
    out.append(f'<pre class="signature">{_esc(sig)}</pre>')
    if body:
        out.append(f'<div class="doc">{body}</div>')
    out.append("</div>")
    return "".join(out)


def section(full_name, label, anchor, entries, docs, first, eyebrow):
    types = sorted([e for e in entries if e[0] in TYPE_KINDS], key=lambda e: e[1].lower())
    fns = sorted([e for e in entries if e[0] not in TYPE_KINDS], key=lambda e: e[1].lower())
    cls = "section first" if first else "section"
    out = [f'<section class="{cls}" id="{anchor}">']
    out.append(f'<p class="{eyebrow}">{_esc(full_name)}</p>')
    out.append(f"<h2>{_esc(label)}</h2>")
    for title, group in (("Types", types), ("Functions &amp; methods", fns)):
        if not group:
            continue
        out.append(f'<h3>{title} <span class="count">{len(group)}</span></h3>')
        for kind, key, sig in group:
            out.append(render_entry(kind, sig, docs.get(key, "")))
    out.append("</section>")
    return "\n".join(out)


def build(site):
    sections, nav, total = [], [], 0
    first = True
    # the façade re-exports its members, so a name documented in `schema` must be
    # documented on the façade page too: one map for the whole repository
    docs = {}
    for pkg_dir, _full, _label, _anchor in site["packages"]:
        for key, text in parse_docs(os.path.join(ROOT, pkg_dir)).items():
            docs.setdefault(key, text)

    for pkg_dir, full, label, anchor in site["packages"]:
        mbti = os.path.join(ROOT, pkg_dir, "pkg.generated.mbti")
        if not os.path.exists(mbti):
            sys.stderr.write(f"warn: missing {pkg_dir}/pkg.generated.mbti, skipping\n")
            continue
        entries = [e for e in parse_mbti(mbti)
                   if not (e[1].split("::")[-1] in DERIVED and not docs.get(e[1]))]
        total += len(entries)
        sections.append(section(full, label, anchor, entries, docs, first, site["eyebrow"]))
        first = False
        nav.append(f'<a href="#{anchor}">{label}<span class="n">{len(entries)}</span></a>')
    return "\n".join(nav), "\n".join(sections), total, len(nav)





def main():
    check = "--check" in sys.argv
    stale = []
    for site in SITES:
        nav, sections, total, count = build(site)
        with open(os.path.join(ROOT, site["template"]), encoding="utf-8") as fh:
            shell = fh.read()
        html = (shell.replace("{NAV}", nav)
                     .replace("{SECTIONS}", sections)
                     .replace("{TOTAL}", f"{total}")
                     .replace("{COUNT}", f"{count}"))
        out_path = os.path.join(ROOT, site["out"])
        current = ""
        if os.path.exists(out_path):
            with open(out_path, encoding="utf-8") as fh:
                current = fh.read()
        if current == html:
            continue
        stale.append(site["out"])
        if not check:
            with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(html)
    if check and stale:
        sys.stderr.write(", ".join(stale) + " stale; run python3 scripts/gen_api.py\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
