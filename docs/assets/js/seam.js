// moonorm · hero seam — compile-time stitching demo (real mapping, real break)
(function () {
  "use strict";
  var stage = document.querySelector(".seam-stage");
  if (!stage) return;

  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var leftWorld = stage.querySelector(".world.left");
  var rightWorld = stage.querySelector(".world.right");
  var seamCol = stage.querySelector(".seam");
  var flag = seamCol && seamCol.querySelector(".seam-flag");
  var stitch = seamCol && seamCol.querySelector(".seam-stitch");
  var diag = document.getElementById("seam-diagnostic");
  var diagBadge = diag && diag.querySelector(".badge");
  var diagMsg = diag && diag.querySelector(".msg");
  var genSql = document.getElementById("seam-gen-sql");

  // ordered field list: MoonBit type -> SQL type. `broken` fields fail the seam.
  var fields = [
    { k: "id",     lt: "Int64",  rt: "BIGINT", broken: false },
    { k: "name",   lt: "String", rt: "TEXT",   broken: false },
    { k: "email",  lt: "String", rt: "TEXT",   broken: false, fault: true }
  ];

  var leftNodes = {}, rightNodes = {}, beams = [];
  // nodes are static in the HTML (works without JS); we only add decorative beams
  fields.forEach(function (f) {
    leftNodes[f.k] = leftWorld.querySelector('.node[data-field="' + f.k + '"]');
    rightNodes[f.k] = rightWorld.querySelector('.node[data-field="' + f.k + '"]');
    var b = document.createElement("div");
    b.className = "beam"; b.dataset.field = f.k;
    stage.appendChild(b); beams.push(b);
  });

  // position each beam at the vertical centre of its pair of nodes
  function layout() {
    fields.forEach(function (f) {
      var ln = leftNodes[f.k], rn = rightNodes[f.k];
      var y = (ln.offsetTop + ln.offsetHeight / 2 + rn.offsetTop + rn.offsetHeight / 2) / 2 - stage.offsetTop;
      var b = beams[fields.indexOf(f)];
      b.style.top = y + "px";
    });
  }
  layout();
  window.addEventListener("resize", layout);

  function setMapped(f) {
    var ok = !f.broken;
    leftNodes[f.k].classList.toggle("broken", !ok);
    rightNodes[f.k].classList.toggle("broken", !ok);
    var b = beams[fields.indexOf(f)];
    b.classList.toggle("broken", !ok);
  }

  // ---- diagnostic + generated SQL reflect the current state ----
  function refreshState() {
    var anyBroken = fields.some(function (f) { return f.broken; });
    if (diag) {
      if (anyBroken) {
        diag.classList.add("err"); diag.classList.remove("ok");
        if (diagBadge) diagBadge.textContent = "error:";
        if (diagMsg) diagMsg.textContent = "type mismatch at field email — expected TEXT, found Int";
      } else {
        diag.classList.add("ok"); diag.classList.remove("err");
        if (diagBadge) diagBadge.textContent = "✓";
        if (diagMsg) diagMsg.textContent = "all fields mapped, 0 errors";
      }
    }
    if (genSql) {
      genSql.textContent = anyBroken
        ? "-- compile aborts: field email cannot be stitched to TEXT"
        : "SELECT id, name, email\n  FROM users\n WHERE id = ?";
    }
  }

  // ---- hover: lock one field's mapping ----
  fields.forEach(function (f) {
    [leftNodes[f.k], rightNodes[f.k]].forEach(function (n) {
      n.addEventListener("mouseenter", function () { highlight(f.k); });
      n.addEventListener("mouseleave", function () { if (!cycling) clearHighlight(); });
    });
    // click email to trigger the fault on demand (also auto-cycles below)
    if (f.fault) {
      [leftNodes[f.k], rightNodes[f.k]].forEach(function (n) {
        n.style.cursor = "pointer";
        n.addEventListener("click", function () { toggleFault(); });
      });
    }
  });
  function highlight(k) {
    fields.forEach(function (f) {
      var on = f.k === k;
      leftNodes[f.k].classList.toggle("sel", on);
      rightNodes[f.k].classList.toggle("sel", on);
      beams[fields.indexOf(f)].classList.toggle("lit", on);
    });
  }
  function clearHighlight() {
    fields.forEach(function (f) {
      leftNodes[f.k].classList.remove("sel");
      rightNodes[f.k].classList.remove("sel");
      beams[fields.indexOf(f)].classList.remove("lit");
    });
  }

  // ---- auto cycle: stitch each field in turn ----
  var cycling = true, idx = 0;
  function cycle() {
    if (reduce) return;
    var f = fields[idx % fields.length];
    highlight(f.k);
    if (flag) flag.textContent = "stitching " + f.k;
    idx++;
    if (idx % fields.length === 0) {
      // brief pause on the whole mapping, then a fault flash
      setTimeout(function () {
        if (cycling) { triggerFault(); }
      }, 900);
    }
  }
  var cycleTimer = reduce ? null : setInterval(cycle, 1400);

  // ---- fault demo: flip email to Int, the seam breaks, then heals ----
  var faultActive = false;
  function triggerFault() {
    if (faultActive) return;
    faultActive = true;
    var ef = fields.filter(function (f) { return f.fault; })[0];
    ef.broken = true; ef.lt = "Int";
    leftNodes[ef.k].querySelector(".v").textContent = ": Int";
    setMapped(ef); refreshState();
    clearHighlight();
    highlight(ef.k);
    if (flag) flag.textContent = "✗ break at email";
    if (stitch) stitch.style.background = "var(--broken)";
    setTimeout(healFault, 2200);
  }
  function healFault() {
    var ef = fields.filter(function (f) { return f.fault; })[0];
    ef.broken = false; ef.lt = "String";
    leftNodes[ef.k].querySelector(".v").textContent = ": String";
    setMapped(ef); refreshState();
    clearHighlight();
    if (flag) flag.textContent = "seam steady";
    faultActive = false;
  }
  function toggleFault() {
    if (cycleTimer) { clearInterval(cycleTimer); cycleTimer = null; cycling = false; }
    if (faultActive) healFault(); else triggerFault();
  }

  refreshState();
  layout();
})();
