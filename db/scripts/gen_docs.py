#!/usr/bin/env python3
"""Generate a self-contained, styled API-reference site (docs/index.html) for
gh-pages from the package sources' `///` doc comments. Reproducible: it reads the
.mbt files, so the docs never drift from the code."""
import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# One logical section per source file, in reading order.
SECTIONS = [
    ("Value", "value.mbt",
     "The dialect-neutral cell — the unit that crosses the driver boundary in both directions."),
    ("Errors", "error.mbt",
     "The single error type every fallible operation raises."),
    ("Row & ExecResult", "row.mbt",
     "A result row with typed accessors, and the outcome of a non-query statement."),
    ("Driver", "driver.mbt",
     "The contract a backend implements and a query layer targets — the seam moondb exists to define."),
    ("MockDriver", "mock.mbt",
     "A dependency-free, in-memory reference driver: proof the interface is implementable, and a test double for layers built on it."),
    ("Pool", "pool.mbt",
     "A fixed-ceiling connection pool over any driver: reuse idle connections, cap the open count, evict dead connections with a pre_ping health probe, retire ones past their max_lifetime, offer a non-blocking try_acquire, and close them all."),
]

OPENERS = ("enum", "struct", "trait", "suberror")


def strip_vis(s):
    for p in ("pub(all) ", "pub(open) ", "pub "):
        if s.startswith(p):
            return s[len(p):]
    return None


def parse(path):
    """Return [(kind, signature, doc)]. For enum/struct/trait/suberror the
    signature is the whole multi-line block (members included); for fn/impl/let it
    is the single-line head."""
    lines = path.read_text(encoding="utf-8").splitlines()
    items, doc, i = [], [], 0
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()
        if s == "///|":
            doc = []
            i += 1
            continue
        if s.startswith("///"):
            doc.append(s[3:].strip())
            i += 1
            continue
        body = strip_vis(s)
        if body is None:
            if s == "":
                pass
            else:
                doc = []
            i += 1
            continue
        head = body.split("(")[0].split()[0] if body.split() else ""
        kind = head if head in OPENERS else (
            "fn" if body.startswith("fn") else
            "let" if body.startswith("let") else
            "impl" if body.startswith("impl") else "item")
        if kind in OPENERS and body.rstrip().endswith("{"):
            block = [body]
            depth = body.count("{") - body.count("}")
            j = i + 1
            while j < len(lines) and depth > 0:
                block.append(lines[j])
                depth += lines[j].count("{") - lines[j].count("}")
                j += 1
            sig = "\n".join(block)
            i = j
        else:
            sig = re.sub(r"\s*\{.*$", "", body).rstrip()
            i += 1
        items.append((kind, sig, " ".join(doc).strip()))
        doc = []
    return items


def tint(sig):
    s = html.escape(sig)
    s = re.sub(r"\b(pub|fn|struct|enum|trait|suberror|impl|let|for|with|raise|mut)\b",
               r'<span class="k">\1</span>', s)
    s = re.sub(r"\b([A-Z][A-Za-z0-9_]*)\b", r'<span class="ty">\1</span>', s)
    s = s.replace("-&gt;", '<span class="op">-&gt;</span>')
    return s


def prose(t):
    t = html.escape(t)
    t = re.sub(r"\[`([^`]+)`\]", r"<code>\1</code>", t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    # Render `*`-bullet runs (flattened onto one line by the doc joiner) as breaks.
    t = re.sub(r"\s*\*\s+", "<br>&bull; ", t)
    return t


CSS = r"""
:root{
  --bg:#fbfbfd; --panel:#ffffff; --panel-2:#f6f7fb; --ink:#14181f;
  --muted:#5b6675; --line:#e8ebf1; --accent:#2f7d6e; --accent-soft:#e4f3ef; --out:#0ca678;
  --code-bg:#f4f5f9; --shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0b0e14; --panel:#131722; --panel-2:#0f131c; --ink:#e9edf6; --muted:#96a1b5;
  --line:#212736; --accent:#48c9b0; --accent-soft:#122a26; --out:#2dd4a7;
  --code-bg:#161b26; --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5);
}}
:root[data-theme=light]{--bg:#fbfbfd;--panel:#fff;--panel-2:#f6f7fb;--ink:#14181f;--muted:#5b6675;--line:#e8ebf1;--accent:#2f7d6e;--accent-soft:#e4f3ef;--out:#0ca678;--code-bg:#f4f5f9;--shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10)}
:root[data-theme=dark]{--bg:#0b0e14;--panel:#131722;--panel-2:#0f131c;--ink:#e9edf6;--muted:#96a1b5;--line:#212736;--accent:#48c9b0;--accent-soft:#122a26;--out:#2dd4a7;--code-bg:#161b26;--shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5)}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
  font-size:15.5px;line-height:1.6;-webkit-font-smoothing:antialiased}
code,pre,.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:264px minmax(0,1fr);max-width:1180px;margin:0 auto}
.sidebar{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;
  border-right:1px solid var(--line);padding:1.6rem 1.1rem 2rem;background:var(--panel-2)}
.brand{display:flex;align-items:center;gap:.55rem;font-family:"IBM Plex Mono";font-weight:600;
  font-size:1.35rem;letter-spacing:-.01em;color:var(--ink);margin-bottom:.15rem}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.brand-sub{color:var(--muted);font-size:.8rem;margin:0 0 1.3rem;padding-left:.15rem}
.side-nav{display:flex;flex-direction:column;gap:.1rem}
.side-nav a{color:var(--muted);font-size:.9rem;padding:.32rem .6rem;border-radius:8px;
  font-family:"IBM Plex Mono";display:flex;align-items:center;gap:.4rem;border-left:2px solid transparent}
.side-nav a .at{color:var(--accent);opacity:.6}
.side-nav a:hover{background:var(--accent-soft);color:var(--ink);text-decoration:none}
.side-nav a.active{color:var(--ink);background:var(--accent-soft);border-left-color:var(--accent);font-weight:500}
.side-nav a.active .at{opacity:1}
.side-foot{margin-top:1.6rem;padding-top:1.1rem;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:.4rem}
.side-foot img{height:20px;display:block}
.theme-btn{margin-top:1rem;background:none;border:1px solid var(--line);color:var(--muted);
  border-radius:8px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer;width:100%}
.theme-btn:hover{border-color:var(--accent);color:var(--ink)}
main{padding:2.6rem 2.4rem 5rem;min-width:0}
.hero h1{font-family:"IBM Plex Mono";font-weight:600;font-size:2.9rem;letter-spacing:-.02em;margin:0}
.hero .tag{color:var(--muted);font-size:1.12rem;max-width:62ch;margin:.5rem 0 1.1rem;text-wrap:balance}
.badges{display:flex;flex-wrap:wrap;gap:.45rem;margin:0 0 1.4rem}
.badges img{height:21px;display:block}
.install{display:flex;align-items:center;gap:.6rem;background:var(--panel);border:1px solid var(--line);
  border-radius:12px;padding:.65rem 1rem;box-shadow:var(--shadow);max-width:420px}
.install .prompt{color:var(--out);user-select:none;font-weight:600}
.install code{flex:1;font-size:.95rem}
.copy{background:none;border:1px solid var(--line);border-radius:7px;color:var(--muted);
  cursor:pointer;font:inherit;font-size:.72rem;padding:.2rem .5rem}
.copy:hover{border-color:var(--accent);color:var(--accent)}
.copy.ok{color:var(--out);border-color:var(--out)}
.lede{margin:2rem 0 .5rem;background:
   radial-gradient(120% 130% at 100% 0%, var(--accent-soft) 0%, transparent 55%), var(--panel);
  border:1px solid var(--line);border-radius:16px;padding:1.2rem 1.4rem;box-shadow:var(--shadow)}
.lede h2{margin:0 0 .4rem;font-size:1.05rem;display:flex;align-items:center;gap:.5rem}
.lede h2 .spark{color:var(--accent)}
.lede p{margin:.2rem 0;color:var(--muted);font-size:.95rem}
.lede code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.88em;color:var(--accent)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:"IBM Plex Mono";font-size:1.55rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent)}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--c,var(--accent));background:color-mix(in oklab,var(--c,var(--accent)) 13%,transparent);
  border:1px solid color-mix(in oklab,var(--c,var(--accent)) 30%,transparent)}
.item[data-k=struct] .kind{--c:#8b5cf6}.item[data-k=enum] .kind{--c:#8b5cf6}
.item[data-k=fn] .kind{--c:#0ca678}.item[data-k=trait] .kind{--c:#e08c1f}
.item[data-k=suberror] .kind{--c:#d6455d}.item[data-k=impl] .kind{--c:#2563eb}
.sig{font-size:.95rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem;line-height:1.5}
.sig .k{color:#8b5cf6;font-weight:500}.sig .ty{color:var(--accent)}.sig .op{color:var(--muted)}
@media (prefers-color-scheme:dark){.sig .k{color:#b794ff}}
.doc{margin:0;color:var(--ink);max-width:78ch}
.doc code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.9em;color:var(--accent)}
footer{margin-top:3rem;padding-top:1.3rem;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
@media (max-width:820px){
  .layout{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;border-right:none;border-bottom:1px solid var(--line)}
  .side-nav{flex-flow:row wrap}.side-nav a{border-left:none}.side-nav a.active{border-left:none}
  main{padding:1.8rem 1.2rem 4rem}.hero h1{font-size:2.2rem}
}
"""

JS = r"""
document.addEventListener("DOMContentLoaded",()=>{
  document.querySelectorAll("[data-copy]").forEach(btn=>btn.addEventListener("click",()=>{
    navigator.clipboard.writeText(btn.getAttribute("data-copy")).then(()=>{
      const t=btn.textContent;btn.textContent="copied";btn.classList.add("ok");
      setTimeout(()=>{btn.textContent=t;btn.classList.remove("ok");},1100);});}));
  const links=[...document.querySelectorAll(".side-nav a")];
  const map=Object.fromEntries(links.map(a=>[a.getAttribute("href").slice(1),a]));
  const spy=new IntersectionObserver(es=>{es.forEach(e=>{if(e.isIntersecting){
    links.forEach(a=>a.classList.remove("active"));const a=map[e.target.id];if(a)a.classList.add("active");}});},
    {rootMargin:"-10% 0px -80% 0px"});
  document.querySelectorAll("section.pkg").forEach(s=>spy.observe(s));
  const tb=document.getElementById("theme");if(tb)tb.addEventListener("click",()=>{
    const cur=document.documentElement.getAttribute("data-theme")
      ||(matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light");
    document.documentElement.setAttribute("data-theme",cur==="dark"?"light":"dark");});
});
"""


def slug(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def main():
    HEAD = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>moondb — MoonBit database-access interface</title>'
            '<link rel="preconnect" href="https://fonts.googleapis.com">'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
            '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&'
            'family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">'
            '<style>' + CSS + '</style></head><body>')

    side = ['<aside class="sidebar"><div class="brand"><span class="dot"></span>moondb</div>'
            '<p class="brand-sub">the DB-access interface for MoonBit</p><nav class="side-nav">']
    side += ['<a href="#%s"><span class="at">#</span>%s</a>' % (slug(t), t) for t, _, _ in SECTIONS]
    side += ['</nav>'
             '<button class="theme-btn" id="theme">◐ toggle theme</button>'
             '<div class="side-foot">'
             '<a href="https://github.com/moonbitstack/moonorm/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moonorm/ci.yml?branch=master&label=CI&logo=github"></a>'
             '<a href="https://mooncakes.io/docs/Lfan-ke/moondb"><img alt="mooncakes" src="https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoondb-1f6feb"></a>'
             '</div></aside>']

    hero = ('<main><header class="hero"><h1>moondb</h1>'
            '<p class="tag">The standard database-access interface for MoonBit — the pure, '
            'zero-dependency contract between database <em>drivers</em> and query <em>layers</em>, '
            'transliterated from Go\'s <code>database/sql/driver</code> and Python\'s DB-API 2.0.</p>'
            '<div class="badges">'
            '<a href="https://github.com/moonbitstack/moonorm/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moonorm/ci.yml?branch=master&label=CI&logo=github"></a>'
            '<img alt="tests" src="https://img.shields.io/badge/tests-19%20passing-0ca678">'
            '<a href="https://github.com/moonbitstack/moonorm/tree/master/db"><img alt="GitHub" src="https://img.shields.io/badge/GitHub-source-24292f?logo=github"></a>'
            '<img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-2f7d6e"></div>'
            '<div class="install"><span class="prompt">$</span><code>moon add Lfan-ke/moondb</code>'
            '<button class="copy" data-copy="moon add Lfan-ke/moondb">copy</button></div>'
            '<div class="lede"><h2><span class="spark">✦</span> One contract, two sides</h2>'
            '<p><code>@moondb</code> defines the boundary every SQL backend implements and every ORM / query '
            'builder targets. A driver implements <code>Driver</code> once and works under every query layer; '
            'a query layer targets <code>Driver</code> once and runs on every backend.</p>'
            '<p><b>The binding contract:</b> <code>execute</code> / <code>query</code> take '
            '<code>(sql, params)</code> — positional placeholders in the SQL, one <code>Value</code> per '
            'placeholder in order. Values bind out-of-band, never spliced into the string.</p></div></header>')

    body = [HEAD, '<div class="layout">'] + side + [hero]
    total = 0
    for title, rel, desc in SECTIONS:
        body.append('<section class="pkg" id="%s"><h2><span class="at">#</span>%s</h2>'
                    '<p class="pdesc">%s</p>' % (slug(title), title, esc(desc)))
        for kind, sig, doc in parse(ROOT / rel):
            total += 1
            body.append('<div class="item" data-k="%s"><span class="kind">%s</span>'
                        '<pre class="sig">%s</pre>%s</div>'
                        % (kind, kind, tint(sig), ('<p class="doc">%s</p>' % prose(doc)) if doc else ''))
        body.append('</section>')
    body.append('<footer>Generated from source <code>///</code> doc-comments · '
                '<a href="https://mooncakes.io/docs/Lfan-ke/moondb">mooncakes</a> · '
                '<a href="https://github.com/moonbitstack/moonorm/tree/master/db">GitHub</a> · Apache-2.0 © Leo Cheng</footer>')
    body.append('</main></div><script>' + JS + '</script></body></html>')

    out = ROOT / "docs" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(body), encoding="utf-8")
    print("wrote %s (%d public items across %d sections)" % (out, total, len(SECTIONS)))


def esc(t):
    return html.escape(t)


if __name__ == "__main__":
    main()
