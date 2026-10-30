/* The SQL on these pages is what the engine returned. This only lays it out,
   one clause to a line with its list items and conditions indented, and
   colours it; no character other than whitespace changes. */
(function () {
  // A clause whose body follows on its own indented lines.
  var BLOCK = { "SELECT": 1, "SELECT DISTINCT": 1, "FROM": 1, "WHERE": 1, "SET": 1, "VALUES": 1, "HAVING": 1, "RETURNING": 1 };
  // A clause that keeps its body on the same line.
  var INLINE = {
    "WITH": 1, "GROUP BY": 1, "ORDER BY": 1, "LIMIT": 1, "OFFSET": 1, "UNION": 1, "UNION ALL": 1,
    "INTERSECT": 1, "EXCEPT": 1, "INSERT INTO": 1, "UPDATE": 1, "DELETE FROM": 1, "ON CONFLICT": 1,
    "FOR UPDATE": 1, "FOR SHARE": 1, "JOIN": 1, "LEFT JOIN": 1, "RIGHT JOIN": 1, "INNER JOIN": 1,
    "FULL JOIN": 1, "CROSS JOIN": 1, "CREATE TABLE": 1, "CREATE INDEX": 1, "CREATE UNIQUE": 1
  };
  // Lists that break after each comma.
  var LISTS = { "SELECT": 1, "SELECT DISTINCT": 1, "SET": 1, "VALUES": 1, "RETURNING": 1 };
  var KEYWORDS = new Set((
    "SELECT DISTINCT FROM WHERE AND OR NOT NULL IS IN AS ON USING JOIN LEFT RIGHT INNER OUTER FULL CROSS " +
    "GROUP BY HAVING ORDER ASC DESC NULLS FIRST LAST LIMIT OFFSET UNION ALL INTERSECT EXCEPT INSERT INTO " +
    "VALUES UPDATE SET DELETE RETURNING CONFLICT DO NOTHING CREATE TABLE INDEX UNIQUE PRIMARY KEY FOREIGN " +
    "REFERENCES DEFAULT CHECK CONSTRAINT IF EXISTS DROP ALTER ADD COLUMN LIKE ILIKE BETWEEN CASE WHEN THEN " +
    "ELSE END WITH RECURSIVE FOR SHARE NOWAIT SKIP LOCKED CASCADE RESTRICT ENGINE INTEGER INT BIGINT " +
    "SMALLINT TEXT REAL BOOLEAN BLOB BYTEA BIGSERIAL SERIAL AUTOINCREMENT AUTO_INCREMENT VARCHAR CHAR " +
    "TIMESTAMP DATE TIME DOUBLE PRECISION NUMERIC DECIMAL COUNT SUM AVG MIN MAX COALESCE TRUE FALSE"
  ).split(" "));
  var TOKEN = /\s+|'(?:[^']|'')*'|"(?:[^"]|"")*"|`[^`]*`|\$\d+|\?|:\w+|\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|<>|<=|>=|!=|\|\||./g;

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function paint(tok) {
    if (KEYWORDS.has(tok)) return '<span class="sql-kw">' + esc(tok) + "</span>";
    if (tok[0] === "'") return '<span class="sql-str">' + esc(tok) + "</span>";
    if (/^(\$\d+|\?|:\w+|\d)/.test(tok)) return '<span class="sql-arg">' + esc(tok) + "</span>";
    return esc(tok);
  }

  function layout(sql) {
    var t = (sql.match(TOKEN) || []).filter(function (x) { return x.length; });
    var words = [], gaps = [];
    for (var i = 0, gap = ""; i < t.length; i++) {
      if (/^\s+$/.test(t[i])) { gap += t[i]; continue; }
      words.push(t[i]); gaps.push(gap.indexOf("\n") >= 0 ? "\n" : gap ? " " : ""); gap = "";
    }
    var up = function (k) { return words[k] && /^[A-Za-z_]/.test(words[k]) ? words[k].toUpperCase() : ""; };
    var out = "", depth = 0, clause = "", ddl = 0, brk = false;
    for (var k = 0; k < words.length; k++) {
      var w = words[k], u = up(k), name = "", span = 1;
      if (depth === 0 && u) {
        var two = u + " " + up(k + 1);
        if (BLOCK[two] || INLINE[two]) { name = two; span = 2; }
        else if (BLOCK[u] || INLINE[u]) name = u;
      }
      var sep = gaps[k];
      if (name) {
        sep = out ? "\n" : "";
        clause = name;
      } else if (w === ")" && ddl && depth === ddl) {
        sep = "\n";
      } else if (brk) {
        sep = "\n  ";
      } else if (depth === 0 && (u === "AND" || u === "OR") && (clause === "WHERE" || clause === "HAVING")) {
        sep = "\n  ";
      }
      brk = false;
      out += sep;
      for (var s = 0; s < span; s++) out += (s ? gaps[k + s] : "") + paint(words[k + s]);
      if (name) {
        k += span - 1;
        brk = !!BLOCK[name];
        continue;
      }
      if (w === "(") {
        depth++;
        if (depth === 1 && clause === "CREATE TABLE" && !ddl) { ddl = 1; brk = true; }
      } else if (w === ")") {
        if (ddl && depth === ddl) ddl = 0;
        depth = Math.max(0, depth - 1);
      } else if (w === ",") {
        if ((depth === 0 && LISTS[clause]) || (ddl && depth === ddl)) brk = true;
      }
    }
    return out;
  }

  globalThis.moonormSql = {
    show: function (el, sql) { el.innerHTML = layout(sql); }
  };
})();
