#!/usr/bin/env python3
"""Generate a self-contained, styled API-reference site (docs/index.html) for
gh-pages from the package sources' `///` doc comments. Reproducible: reads the
.mbt files, so the docs never drift from the code."""
import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKGS = [
    ("error", "error.mbt",
     "The driver's one error type, for the protocol failures the server and the wire can produce."),
    ("packet", "packet.mbt",
     "The MySQL packet codec: length-encoded and fixed-width little-endian integers, NUL- and lenenc-strings, over an in-memory cursor."),
    ("handshake", "handshake.mbt",
     "Protocol-10 handshake parsing, capability flags, the mysql_native_password scramble, and the HandshakeResponse41 builder."),
    ("caching_sha2", "caching_sha2.mbt",
     "MySQL 8's default authentication: the fast-auth scramble, and the full-auth token RSA-OAEP encrypted to the server's public key."),
    ("ed25519", "ed25519.mbt",
     "MariaDB's client_ed25519 authentication response; the signature itself is mooncrypt's."),
    ("response", "response.mbt",
     "OK / ERR / EOF classification, column-definition parsing, and the text-protocol result-set decoder into @moondb rows."),
    ("binding", "binding.mbt",
     "Quote-aware parameter binding: `?` placeholders substituted with escaped SQL literals (out-of-band binding lands with prepared statements)."),
    ("client · MysqlConn", "client/conn.mbt",
     "The asynchronous socket transport: connect + mysql_native_password auth + COM_QUERY over @socket.Tcp, with real transactions."),
    ("client · MysqlDriver", "client/driver.mbt",
     "The synchronous @moondb.Driver adapter that bridges each call through the async runtime (autocommit; reconnect-per-call)."),
]


def parse(path):
    items, doc = [], []
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if s == "///|":
            doc = []
        elif s.startswith("///"):
            doc.append(s[3:].strip())
        elif s.startswith("pub"):
            body = s
            for prefix in ("pub(all) ", "pub(open) ", "pub "):
                if body.startswith(prefix):
                    body = body[len(prefix):]
                    break
            else:
                doc = []
                continue
            if body.startswith("impl"):
                doc = []
                continue
            body = body.replace("async fn", "fn")
            sig = re.sub(r"\s*\{.*$", "", body).rstrip()
            first = sig.split()[0] if sig.split() else ""
            kind = {"struct": "struct", "enum": "enum", "fn": "fn", "let": "let",
                    "trait": "trait", "suberror": "suberror", "type": "type",
                    "const": "const"}.get(first, "item")
            items.append((kind, sig, " ".join(doc).strip()))
            doc = []
        elif s == "":
            pass
        else:
            doc = []
    return items


def tint(sig):
    s = html.escape(sig)
    s = re.sub(r"\b(fn|struct|let|enum|trait|suberror|type|const)\b", r'<span class="k">\1</span>', s)
    s = re.sub(r"\b([A-Z][A-Za-z0-9_]*)\b", r'<span class="ty">\1</span>', s)
    s = s.replace("-&gt;", '<span class="op">-&gt;</span>').replace("?", '<span class="op">?</span>')
    return s


def prose(t):
    t = html.escape(t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


CSS = r"""
:root{
  --bg:#fbfbfd; --panel:#ffffff; --panel-2:#f6f7fb; --ink:#14181f;
  --muted:#5b6675; --line:#e8ebf1; --accent:#0a7ea4; --accent-soft:#e2f3f9; --out:#0ca678;
  --code-bg:#f4f5f9; --shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0b0e14; --panel:#131722; --panel-2:#0f131c; --ink:#e9edf6; --muted:#96a1b5;
  --line:#212736; --accent:#38bdf8; --accent-soft:#0c2733; --out:#2dd4a7;
  --code-bg:#161b26; --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5);
}}
:root[data-theme=light]{--bg:#fbfbfd;--panel:#fff;--panel-2:#f6f7fb;--ink:#14181f;--muted:#5b6675;--line:#e8ebf1;--accent:#0a7ea4;--accent-soft:#e2f3f9;--out:#0ca678;--code-bg:#f4f5f9;--shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10)}
:root[data-theme=dark]{--bg:#0b0e14;--panel:#131722;--panel-2:#0f131c;--ink:#e9edf6;--muted:#96a1b5;--line:#212736;--accent:#38bdf8;--accent-soft:#0c2733;--out:#2dd4a7;--code-bg:#161b26;--shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5)}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
  font-size:15.5px;line-height:1.6;-webkit-font-smoothing:antialiased}
code,pre,.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:288px minmax(0,1fr);max-width:1180px;margin:0 auto}
.sidebar{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;
  border-right:1px solid var(--line);padding:1.6rem 1.1rem 2rem;background:var(--panel-2)}
.brand{display:flex;align-items:center;gap:.55rem;font-family:"IBM Plex Mono";font-weight:600;
  font-size:1.2rem;letter-spacing:-.01em;color:var(--ink);margin-bottom:.15rem}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.brand-sub{color:var(--muted);font-size:.8rem;margin:0 0 1.3rem;padding-left:.15rem}
.side-nav{display:flex;flex-direction:column;gap:.1rem}
.side-nav a{color:var(--muted);font-size:.86rem;padding:.32rem .6rem;border-radius:8px;
  font-family:"IBM Plex Mono";display:flex;align-items:center;gap:.4rem;border-left:2px solid transparent}
.side-nav a .at{color:var(--accent);opacity:.6}
.side-nav a:hover{background:var(--accent-soft);color:var(--ink);text-decoration:none}
.side-nav a.active{color:var(--ink);background:var(--accent-soft);border-left-color:var(--accent);font-weight:500}
.side-foot{margin-top:1.6rem;padding-top:1.1rem;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:.4rem}
.theme-btn{margin-top:1rem;background:none;border:1px solid var(--line);color:var(--muted);
  border-radius:8px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer;width:100%}
.theme-btn:hover{border-color:var(--accent);color:var(--ink)}
main{padding:2.6rem 2.4rem 5rem;min-width:0}
.hero h1{font-family:"IBM Plex Mono";font-weight:600;font-size:2.6rem;letter-spacing:-.02em;margin:0}
.hero .tag{color:var(--muted);font-size:1.1rem;max-width:62ch;margin:.5rem 0 1.1rem;text-wrap:balance}
.badges{display:flex;flex-wrap:wrap;gap:.45rem;margin:0 0 1.4rem}
.badges img{height:21px;display:block}
.install{display:flex;align-items:center;gap:.6rem;background:var(--panel);border:1px solid var(--line);
  border-radius:12px;padding:.65rem 1rem;box-shadow:var(--shadow);max-width:460px}
.install .prompt{color:var(--out);user-select:none;font-weight:600}
.install code{flex:1;font-size:.95rem}
.copy{background:none;border:1px solid var(--line);border-radius:7px;color:var(--muted);
  cursor:pointer;font:inherit;font-size:.72rem;padding:.2rem .5rem}
.copy:hover{border-color:var(--accent);color:var(--accent)}
.copy.ok{color:var(--out);border-color:var(--out)}
.sample{margin:1.6rem 0 .4rem;background:var(--panel);border:1px solid var(--line);border-radius:14px;
  box-shadow:var(--shadow);overflow:hidden}
.sample .bar{display:flex;align-items:center;gap:.5rem;padding:.5rem .9rem;border-bottom:1px solid var(--line);
  background:var(--panel-2);font-family:"IBM Plex Mono";font-size:.78rem;color:var(--muted)}
.sample .bar .d{width:9px;height:9px;border-radius:50%;background:var(--line)}
.sample pre{margin:0;padding:1rem 1.1rem;overflow-x:auto;font-size:.9rem;line-height:1.5}
.sample .k{color:#8b5cf6}.sample .s{color:var(--out)}.sample .c{color:var(--muted)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:"IBM Plex Mono";font-size:1.4rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent)}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in oklab,var(--accent) 26%,transparent)}
.item[data-k=struct] .kind{--c:#8b5cf6}.item[data-k=fn] .kind{--c:#0ca678}.item[data-k=let] .kind{--c:#2563eb}
.item[data-k=enum] .kind{--c:#d97706}.item[data-k=suberror] .kind{--c:#dc2626}
.item .kind{color:var(--c,var(--accent));background:color-mix(in oklab,var(--c,var(--accent)) 13%,transparent);
  border-color:color-mix(in oklab,var(--c,var(--accent)) 30%,transparent)}
.sig{font-size:.96rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem}
.sig .k{color:#8b5cf6;font-weight:500}.sig .ty{color:var(--accent)}.sig .op{color:var(--muted)}
@media (prefers-color-scheme:dark){.sig .k{color:#b794ff}.sample .k{color:#b794ff}}
.doc{margin:0;color:var(--ink);max-width:76ch}
.doc code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.9em;color:var(--accent)}
footer{margin-top:3rem;padding-top:1.3rem;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
@media (max-width:820px){
  .layout{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;border-right:none;border-bottom:1px solid var(--line)}
  .side-nav{flex-flow:row wrap}.side-nav a{border-left:none}.side-nav a.active{border-left:none}
  main{padding:1.8rem 1.2rem 4rem}.hero h1{font-size:2rem}
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

SAMPLE = (
    '<span class="c">// A synchronous @moondb.Driver over MySQL — no C, pure MoonBit.</span>\n'
    '<span class="k">let</span> db = MysqlDriver::new(user=<span class="s">"root"</span>, '
    'password=<span class="s">"root"</span>, database=<span class="s">"test"</span>)\n'
    'db.execute(<span class="s">"CREATE TABLE t (id INT, name TEXT)"</span>, [])\n'
    'db.execute(<span class="s">"INSERT INTO t VALUES (?, ?)"</span>, [Int(1), Text(<span class="s">"a"</span>)])\n'
    '<span class="k">let</span> rows = db.query(<span class="s">"SELECT id, name FROM t"</span>, [])\n'
    'rows[0].int_by(<span class="s">"id"</span>)    <span class="c">// => 1</span>\n'
    'rows[0].text_by(<span class="s">"name"</span>) <span class="c">// => "a"</span>'
)


def esc(t):
    return html.escape(t)


def main():
    HEAD = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>moonmysql — MoonBit API</title>'
            '<link rel="preconnect" href="https://fonts.googleapis.com">'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
            '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&'
            'family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">'
            '<style>' + CSS + '</style></head><body>')

    side = ['<aside class="sidebar"><div class="brand"><span class="dot"></span>moonmysql</div>'
            '<p class="brand-sub">MoonBit API reference</p><nav class="side-nav">']
    side += ['<a href="#%s"><span class="at">@</span>%s</a>' % (slug(n), n) for n, _, _ in PKGS]
    side += ['</nav>'
             '<button class="theme-btn" id="theme">◐ toggle theme</button>'
             '<div class="side-foot">'
             '<a href="https://mooncakes.io/docs/moonbitstack/moonmysql"><img alt="mooncakes" '
             'src="https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonmysql-0a7ea4"></a>'
             '</div></aside>']

    hero = ('<main><header class="hero"><h1>moonmysql</h1>'
            '<p class="tag">A pure-MoonBit MySQL wire-protocol driver — no C, like PyMySQL. '
            'Speaks protocol 41, mysql_native_password, and the text protocol over a raw socket, '
            'and implements the <code>@moondb.Driver</code> contract.</p>'
            '<div class="badges">'
            '<a href="https://github.com/moonbitstack/moonorm/actions"><img alt="CI" '
            'src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moonorm/ci.yml?branch=master&label=CI&logo=github"></a>'
            '<img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-0a7ea4">'
            '<a href="https://github.com/moonbitstack/moonorm/tree/master/drivers/mysql"><img alt="GitHub" '
            'src="https://img.shields.io/badge/GitHub-source-24292f?logo=github"></a></div>'
            '<div class="install"><span class="prompt">$</span><code>moon add moonbitstack/moonmysql</code>'
            '<button class="copy" data-copy="moon add moonbitstack/moonmysql">copy</button></div>'
            '<div class="sample"><div class="bar"><span class="d"></span>roundtrip.mbt</div>'
            '<pre>' + SAMPLE + '</pre></div></header>')

    body = [HEAD, '<div class="layout">'] + side + [hero]
    for name, rel, desc in PKGS:
        body.append('<section class="pkg" id="%s"><h2><span class="at">@</span>%s</h2>'
                    '<p class="pdesc">%s</p>' % (slug(name), esc(name), esc(desc)))
        for kind, sig, doc in parse(ROOT / rel):
            body.append('<div class="item" data-k="%s"><span class="kind">%s</span>'
                        '<pre class="sig">%s</pre>%s</div>'
                        % (kind, kind, tint(sig), ('<p class="doc">%s</p>' % prose(doc)) if doc else ''))
        body.append('</section>')
    body.append('<footer>Generated from source <code>///</code> doc-comments · '
                '<a href="https://mooncakes.io/docs/moonbitstack/moonmysql">mooncakes</a> · '
                '<a href="https://github.com/moonbitstack/moonorm/tree/master/drivers/mysql">GitHub</a> · Apache-2.0 © Leo Cheng</footer>')
    body.append('</main></div><script>' + JS + '</script></body></html>')

    out = ROOT / "docs" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(body), encoding="utf-8")
    total = sum(len(parse(ROOT / rel)) for _, rel, _ in PKGS)
    print("wrote %s (%d public items across %d sections)" % (out, total, len(PKGS)))


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


if __name__ == "__main__":
    main()
