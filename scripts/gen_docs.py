#!/usr/bin/env python3
"""Generate a self-contained, styled API-reference site (docs/index.html) for
gh-pages from the package sources' `///` doc comments. Reproducible: reads the
.mbt files, so the docs never drift from the code."""
import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = [
    ("builder", "builder.mbt", "Query builder",
     "select / insert / update / delete builders with WHERE / ORDER BY / LIMIT, "
     "JOIN, GROUP BY / HAVING, WITH common table expressions, and IN (subquery) "
     "predicates. Every builder renders (sql, params) - values are always ? "
     "placeholders, never spliced in, and subquery/CTE params keep SQL text order."),
    ("session", "session.mbt", "Execution layer",
     "An explicit Session over any @moondb.Driver: it runs built statements and "
     "returns typed @moondb.Row values, with depth-tracked nested transactions "
     "(begin_nested returns a named SAVEPOINT handle), isolation-level / read-only "
     "transactions (begin_with renders SET TRANSACTION per dialect), optimistic-locked "
     "updates (modify_versioned raises LostUpdate on a stale version), and eager "
     "relationship loading including N+1-avoiding batch loads (load_batch / "
     "load_one_batch). moonorm owns no driver contract - the seam is @moondb, so a "
     "Session drives moonsqlite, a Postgres backend, or MockDriver."),
    ("models", "models.mbt", "Models & relationships",
     "The declarative model layer: typed columns and Fields, a Model[T] Row<->record "
     "mapper (built by hand or via from_fields from a field list, the shape moonctl "
     "generates), CREATE TABLE DDL, and foreign-key 1:N / N:1 relationships loaded "
     "explicitly via session.load / session.load_one and batched via load_batch (the "
     "faithful attribute-interception equivalent, as Diesel and GORM also make "
     "explicit)."),
    ("migrations", "migrations.mbt", "Schema migrations",
     "Versioned up/down migrations tracked in a schema_migrations table: a Migrator "
     "applies pending versions ascending, is idempotent on re-run, rolls back to a "
     "target version descending, and reports the current version. The Alembic / "
     "diesel-migrations counterpart, run over any @moondb.Driver."),
    ("session_pool", "session_pool.mbt", "Pooled sessions",
     "Session::with_pool borrows a connection for the duration of one call and "
     "returns it with defer, so it comes back on every path including a raise or a "
     "cancellation."),
    ("driver", "db/driver.mbt", "Driver seam",
     "The @moondb contract every backend implements - execute, query, ping, close, "
     "and the transaction verbs. moonorm reaches nothing past this seam, which is "
     "what lets one Session drive SQLite, Postgres, MySQL or MockDriver."),
    ("pool", "db/pool/pool.mbt", "Connection pool",
     "A pool over any Driver: max_size ceiling, max_lifetime retirement, pre_ping "
     "health probing, and an acquire budget. close_all is the graceful half of a "
     "shutdown - nothing in flight is cut off, and in_use_count is what a drain "
     "waits on."),
    ("row", ("db/row.mbt", "db/cursor.mbt", "db/value.mbt"), "Rows and cursors",
     "The typed row a query returns and the cursor that streams them, plus the "
     "Value union every driver marshals to and from."),
    ("error", "db/error.mbt", "Errors",
     "DbError, the one error type the seam raises, so a caller distinguishes a "
     "closed pool from a query failure without knowing which backend it is on."),
    ("mock", "db/mock.mbt", "MockDriver",
     "An in-memory Driver that records what it was asked to run, so the ORM's own "
     "behaviour is testable on every backend without a database."),
    ("sqlite", ("drivers/sqlite/sqlite.mbt", "drivers/sqlite/ffi.mbt"), "SQLite driver",
     "The Driver over the vendored SQLite amalgamation — the only C in the "
     "repository, kept behind the same seam every other backend meets."),
    ("postgres", ("drivers/postgres/driver.mbt", "drivers/postgres/conn.mbt", "drivers/postgres/protocol.mbt",
                  "drivers/postgres/value.mbt", "drivers/postgres/bytes.mbt", "drivers/postgres/placeholder.mbt",
                  "drivers/postgres/aliases.mbt", "drivers/postgres/scram.mbt", "drivers/postgres/md5.mbt"),
     "Postgres driver",
     "The Postgres wire protocol in MoonBit: the startup and authentication "
     "handshakes (SCRAM-SHA-256 and md5), the simple and extended query paths, "
     "$n placeholders, and the type mapping to @moondb.Value."),
    ("mysql", ("drivers/mysql/handshake.mbt", "drivers/mysql/packet.mbt", "drivers/mysql/response.mbt",
               "drivers/mysql/binding.mbt", "drivers/mysql/error.mbt", "drivers/mysql/caching_sha2.mbt",
               "drivers/mysql/ed25519.mbt", "drivers/mysql/digest.mbt"),
     "MySQL and MariaDB driver",
     "The MySQL wire protocol in MoonBit: the handshake and every authentication "
     "plugin a modern server offers — native password, caching_sha2 including the "
     "full RSA path on a cold cache, and MariaDB's client_ed25519 — plus packet "
     "framing, prepared-statement binding and the error mapping."),
    ("integration", ("integration/e2e.mbt", "integration/pool.mbt"), "Integration suite",
     "The checks that run against published packages rather than the working tree: "
     "what is on mooncakes.io actually works together."),
]
KIND = {"struct": "struct", "enum": "enum", "fn": "fn", "type": "type", "let": "let"}


def parse(path):
    items, doc = [], []
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s == "///|":
            doc = []
        elif s.startswith("///"):
            doc.append(s[3:].strip())
        elif s.startswith("pub"):
            buf = s
            is_alias = re.match(r"pub\s+(type|let)\b", buf) is not None
            while (not is_alias and "{" not in buf and i + 1 < len(lines)):
                i += 1
                buf += " " + lines[i].strip()
            core = re.sub(r"\s*\{.*$", "", buf)
            core = re.sub(r"^pub(?:\(all\))?\s+", "", core).strip()
            core = re.sub(r"\s+", " ", core).rstrip(",").rstrip()
            core = re.sub(r",\s*\)", ")", core)
            first = core.split(" ")[0] if core else ""
            items.append((KIND.get(first, "item"), core, " ".join(doc).strip()))
            doc = []
        elif s == "":
            pass
        else:
            doc = []
        i += 1
    return items


def tint(sig):
    s = html.escape(sig)
    s = re.sub(r"\b(fn|struct|enum|type|let|async)\b", r'<span class="k">\1</span>', s)
    s = re.sub(r"\b([A-Z][A-Za-z0-9_]*)\b", r'<span class="ty">\1</span>', s)
    s = s.replace("-&gt;", '<span class="op">-&gt;</span>').replace("?", '<span class="op">?</span>')
    return s


def prose(t):
    t = html.escape(t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


CSS = r"""
:root{
  --bg:#fbfbfd; --panel:#ffffff; --panel-2:#f6f7fb; --ink:#14181f;
  --muted:#5b6675; --line:#e8ebf1; --accent:#6d5efc; --accent-soft:#efecff; --out:#0ca678;
  --code-bg:#f4f5f9; --shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0b0e14; --panel:#131722; --panel-2:#0f131c; --ink:#e9edf6; --muted:#96a1b5;
  --line:#212736; --accent:#9d8bff; --accent-soft:#1c1b3a; --out:#2dd4a7;
  --code-bg:#161b26; --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5);
}}
:root[data-theme=light]{--bg:#fbfbfd;--panel:#fff;--panel-2:#f6f7fb;--ink:#14181f;--muted:#5b6675;--line:#e8ebf1;--accent:#6d5efc;--accent-soft:#efecff;--out:#0ca678;--code-bg:#f4f5f9;--shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10)}
:root[data-theme=dark]{--bg:#0b0e14;--panel:#131722;--panel-2:#0f131c;--ink:#e9edf6;--muted:#96a1b5;--line:#212736;--accent:#9d8bff;--accent-soft:#1c1b3a;--out:#2dd4a7;--code-bg:#161b26;--shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5)}
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
.contract{margin:2.1rem 0 .5rem;background:
   radial-gradient(120% 130% at 100% 0%, var(--accent-soft) 0%, transparent 55%), var(--panel);
  border:1px solid var(--line);border-radius:16px;padding:1.2rem 1.4rem;box-shadow:var(--shadow)}
.contract h2{margin:0 0 .6rem;font-size:1.06rem;display:flex;align-items:center;gap:.5rem}
.contract h2 .spark{color:var(--accent)}
.contract pre{margin:0;overflow-x:auto;font-size:.92rem;line-height:1.7}
.contract .k{color:#8b5cf6;font-weight:500}.contract .ty{color:var(--accent)}.contract .op{color:var(--muted)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:"IBM Plex Mono";font-size:1.55rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent)}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s,transform .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in oklab,var(--accent) 26%,transparent)}
.item[data-k=struct] .kind{--c:#8b5cf6}.item[data-k=fn] .kind{--c:#0ca678}.item[data-k=let] .kind{--c:#2563eb}
.item[data-k=enum] .kind{--c:#d6336c}.item[data-k=type] .kind{--c:#0891b2}
.item .kind{color:var(--c,var(--accent));background:color-mix(in oklab,var(--c,var(--accent)) 13%,transparent);
  border-color:color-mix(in oklab,var(--c,var(--accent)) 30%,transparent)}
.sig{font-size:.98rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem}
.sig .k{color:#8b5cf6;font-weight:500}.sig .ty{color:var(--accent)}.sig .op{color:var(--muted)}
@media (prefers-color-scheme:dark){.sig .k,.contract .k{color:#b794ff}}
.doc{margin:0;color:var(--ink);max-width:76ch}
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

CONTRACT = """let (sql, params) = select("users")
  .column("id").eq("age", Int(18)).order_by("name", Asc).limit(10).build()
// "SELECT id FROM users WHERE age = ? ORDER BY name ASC LIMIT 10", [Int(18)]

// bound values are ? placeholders + a params list => injection-safe by construction."""


def esc(t):
    return html.escape(t)


def main():
    HEAD = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>moonorm — MoonBit SQL toolkit API</title>'
            '<link rel="preconnect" href="https://fonts.googleapis.com">'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
            '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&'
            'family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">'
            '<style>' + CSS + '</style></head><body>')

    side = ['<aside class="sidebar"><div class="brand"><span class="dot"></span>moonorm</div>'
            '<p class="brand-sub">MoonBit SQL toolkit — API reference</p><nav class="side-nav">']
    side += ['<a href="#%s"><span class="at">§</span>%s</a>' % (sid, title)
             for sid, _, title, _ in SECTIONS]
    side += ['</nav>'
             '<button class="theme-btn" id="theme">◐ toggle theme</button>'
             '<div class="side-foot">'
             '<a href="https://github.com/moonbitstack/moonorm/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moonorm/ci.yml?branch=master&label=CI&logo=github"></a>'
             '<a href="https://mooncakes.io/docs/moonbitstack/moonorm"><img alt="mooncakes" src="https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonorm-1f6feb"></a>'
             '</div></aside>']

    hero = ('<main><header class="hero"><h1>moonorm</h1>'
            '<p class="tag">An ORM / SQL toolkit for MoonBit &#8212; a parameterized, injection-safe '
            'query builder, the way SQLAlchemy Core is for Python. Bound values become '
            '? placeholders, never spliced into the SQL string.</p>'
            '<div class="badges">'
            '<a href="https://github.com/moonbitstack/moonorm/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moonorm/ci.yml?branch=master&label=CI&logo=github"></a>'
            '<img alt="tests" src="https://img.shields.io/badge/tests-15%20passing%20%2B%20real%20SQLite-0ca678">'
            '<a href="https://github.com/moonbitstack/moonorm"><img alt="GitHub" src="https://img.shields.io/badge/GitHub-source-24292f?logo=github"></a>'
            '<img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-6d5efc"></div>'
            '<div class="install"><span class="prompt">$</span><code>moon add moonbitstack/moonorm</code>'
            '<button class="copy" data-copy="moon add moonbitstack/moonorm">copy</button></div>'
            '<div class="contract"><h2><span class="spark">&#10038;</span> The contract at a glance</h2>'
            '<pre>' + tint(CONTRACT) + '</pre></div></header>')

    body = [HEAD, '<div class="layout">'] + side + [hero]
    total = 0
    for sid, rel, title, desc in SECTIONS:
        body.append('<section class="pkg" id="%s"><h2><span class="at">§</span>%s</h2>'
                    '<p class="pdesc">%s</p>' % (sid, title, esc(desc)))
        files = rel if isinstance(rel, tuple) else (rel,)
        for kind, sig, doc in [it for f in files for it in parse(ROOT / f)]:
            total += 1
            body.append('<div class="item" data-k="%s"><span class="kind">%s</span>'
                        '<pre class="sig">%s</pre>%s</div>'
                        % (kind, kind, tint(sig), ('<p class="doc">%s</p>' % prose(doc)) if doc else ''))
        body.append('</section>')
    body.append('<footer>Generated from source <code>///</code> doc-comments · '
                '<a href="https://mooncakes.io/docs/moonbitstack/moonorm">mooncakes</a> · '
                '<a href="https://github.com/moonbitstack/moonorm">GitHub</a> · Apache-2.0 &#169; Leo Cheng</footer>')
    body.append('</main></div><script>' + JS + '</script></body></html>')

    out = ROOT / "docs" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(body), encoding="utf-8")
    print("wrote %s (%d public items across %d sections)" % (out, total, len(SECTIONS)))


if __name__ == "__main__":
    main()
