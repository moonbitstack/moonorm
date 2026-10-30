// moonorm · the seam — the home page's mapping ledger, driven by the library.
//
// Every SQL type and every statement shown here comes from
// `globalThis.moonormDemo`, i.e. from this repository compiled to JavaScript by
// the docs workflow. Nothing on the right-hand side is typed by hand: the static
// markup is the PostgreSQL rendering used when the engine has not been built.
(function () {
  "use strict";

  var stage = document.getElementById("seam");
  if (!stage) return;

  var demo = window.moonormDemo;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var rows = [].slice.call(stage.querySelectorAll(".lrow"));
  var diag = document.getElementById("seam-diagnostic");
  var diagBadge = diag && diag.querySelector(".badge");
  var diagMsg = diag && diag.querySelector(".msg");
  var genSql = document.getElementById("seam-gen-sql");
  var genLabel = document.getElementById("seam-gen-label");
  var dialectName = document.getElementById("seam-dialect-name");
  var tabs = [].slice.call(stage.querySelectorAll("[data-dialect]"));

  var DIALECTS = ["SQLite", "PostgreSQL", "MySQL"];

  // ordered field list: the MoonBit type on the left, and the field's index on the right
  var fields = [
    { k: "id", lt: ": Int64" },
    { k: "name", lt: ": String" },
    { k: "email", lt: ": String", fault: true }
  ];

  var parts = {};
  fields.forEach(function (f) {
    var row = stage.querySelector('.lrow[data-field="' + f.k + '"]');
    parts[f.k] = {
      row: row,
      left: row.querySelector(".cell.left"),
      right: row.querySelector(".cell.right"),
      leftType: row.querySelector(".cell.left .typ"),
      rightType: row.querySelector(".cell.right .typ"),
      rightFlag: row.querySelector(".cell.right .flag"),
      suture: row.querySelector(".suture")
    };
  });

  var dialect = 1;          // 1 = PostgreSQL, the default view
  var broken = {};          // field -> true while its fault demo runs

  // ---- render the right column from the library ----
  // `userColumns` returns one "name|type|flags" line per column.
  function renderColumns(d) {
    if (!demo || !demo.userColumns) return;
    var lines = demo.userColumns(d).split("\n");
    fields.forEach(function (f, i) {
      var line = lines[i];
      if (!line) return;
      var cols = line.split("|");
      var p = parts[f.k];
      p.rightType.textContent = cols[1] || "";
      p.rightFlag.textContent = (cols[2] || "").trim();
    });
  }

  function renderDdl(d) {
    if (!demo || !demo.userDdl) return;
    genSql.textContent = demo.userDdl(d);
  }

  // ---- state ----
  function anyBroken() {
    return fields.some(function (f) { return broken[f.k]; });
  }

  function refresh() {
    var bad = anyBroken();
    if (diag) {
      diag.classList.toggle("err", bad);
      diag.classList.toggle("ok", !bad);
      if (diagBadge) diagBadge.textContent = bad ? "error:" : "ok";
      if (diagMsg) {
        diagMsg.textContent = bad
          ? "type mismatch at email \u2014 the column is TEXT, the field is Int"
          : "all fields mapped, 0 errors";
      }
    }
    if (genSql) {
      genSql.classList.toggle("err", bad);
      if (bad) {
        genSql.textContent =
          "error: cannot stitch field `email` to column `email`\n" +
          "  expected  String  \u2192  TEXT\n" +
          "  found     Int     \u2192  no column analogue\n" +
          "  at        struct User, field 3";
      } else {
        renderDdl(dialect);
      }
    }
    if (genLabel) {
      genLabel.textContent = bad ? "compile stopped" : "CREATE TABLE";
    }
  }

  function setDialect(d, name) {
    dialect = d;
    if (dialectName) dialectName.textContent = name;
    tabs.forEach(function (b) {
      b.classList.toggle("on", Number(b.getAttribute("data-dialect")) === d);
    });
    if (!anyBroken()) renderColumns(d);
    refresh();
  }

  // ---- highlight one field: lock its mapping ----
  function highlight(k) {
    fields.forEach(function (f) {
      var on = f.k === k;
      var p = parts[f.k];
      p.left.classList.toggle("sel", on);
      p.right.classList.toggle("sel", on);
      p.suture.classList.toggle("lit", on);
    });
  }
  function clearHighlight() {
    fields.forEach(function (f) {
      var p = parts[f.k];
      p.left.classList.remove("sel");
      p.right.classList.remove("sel");
      p.suture.classList.remove("lit");
    });
  }

  // ---- hover ----
  fields.forEach(function (f) {
    var p = parts[f.k];
    [p.left, p.right].forEach(function (el) {
      el.addEventListener("mouseenter", function () { highlight(f.k); });
      el.addEventListener("mouseleave", function () { if (!cycling) clearHighlight(); });
    });
    if (f.fault) {
      [p.left, p.right].forEach(function (el) {
        el.style.cursor = "pointer";
        el.addEventListener("click", function () { toggleFault(); });
        el.addEventListener("keydown", function (e) {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleFault(); }
        });
      });
    }
  });

  // ---- the fault: flip email to Int and show what the compiler refuses ----
  var faultActive = false, healTimer = null;

  function triggerFault() {
    if (faultActive) return;
    faultActive = true;
    var f = fields.filter(function (x) { return x.fault; })[0];
    broken[f.k] = true;
    var p = parts[f.k];
    p.leftType.textContent = ": Int";
    p.left.classList.add("bad");
    p.right.classList.add("bad");
    p.suture.classList.remove("lit");
    p.suture.classList.add("bad");
    clearHighlight();
    highlight(f.k);
    refresh();
    healTimer = setTimeout(healFault, 2600);
  }

  function healFault() {
    var f = fields.filter(function (x) { return x.fault; })[0];
    broken[f.k] = false;
    faultActive = false;
    clearTimeout(healTimer);
    var p = parts[f.k];
    p.leftType.textContent = f.lt;
    p.left.classList.remove("bad");
    p.right.classList.remove("bad");
    p.suture.classList.remove("bad");
    clearHighlight();
    refresh();
  }

  function toggleFault() {
    stopCycle();
    if (faultActive) healFault(); else triggerFault();
  }

  // ---- auto cycle: stitch each field in turn, then show the fault ----
  var cycling = false, idx = 0, cycleTimer = null;

  function cycle() {
    if (faultActive) return;          // let the break finish playing
    var f = fields[idx % fields.length];
    highlight(f.k);
    idx++;
    if (idx % fields.length === 0) {
      setTimeout(function () { if (cycling && !faultActive) triggerFault(); }, 1100);
    }
  }
  function startCycle() {
    if (reduce || !fields.length) return;
    cycling = true;
    cycleTimer = setInterval(cycle, 1500);
  }
  function stopCycle() {
    cycling = false;
    if (cycleTimer) { clearInterval(cycleTimer); cycleTimer = null; }
  }

  // ---- dialect tabs ----
  tabs.forEach(function (b) {
    b.addEventListener("click", function () {
      stopCycle();
      clearHighlight();
      setDialect(Number(b.getAttribute("data-dialect")), DIALECTS[Number(b.getAttribute("data-dialect"))]);
    });
  });

  // ---- go ----
  if (demo && demo.userColumns) {
    stage.setAttribute("data-live", "1");
    if (genLabel) genLabel.textContent = "CREATE TABLE \u00b7 generated by moonorm";
  }
  renderColumns(dialect);
  refresh();
  startCycle();
})();
