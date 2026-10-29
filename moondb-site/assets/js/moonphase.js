// moondb · moon-phase renderer — the only recurring motif.
// A moon is two equal disks: the lit disk, and a shadow disk offset along the
// horizontal axis. The visible lit fraction is 1 - overlap, where overlap of
// two equal circles at center-distance d is a closed form we invert by search.
(function () {
  "use strict";
  var R = 46, CX = 50, CY = 50;

  function overlap(x) { // x = d / (2R), returns overlapping fraction of one disk
    if (x <= 0) return 1;
    if (x >= 1) return 0;
    return (2 / Math.PI) * (Math.acos(x) - x * Math.sqrt(1 - x * x));
  }
  // lit fraction f -> center distance d, found by binary search on x
  function distForFraction(f) {
    if (f <= 0.001) return 0;
    if (f >= 0.999) return 2 * R; // unused; full is drawn without shadow
    var lo = 0, hi = 1;
    for (var i = 0; i < 40; i++) {
      var mid = (lo + hi) / 2;
      var lit = 1 - overlap(mid);
      if (lit < f) lo = mid; else hi = mid;
    }
    return 2 * R * (lo + hi) / 2;
  }

  // fraction in [0,1]; waxing => lit on the right, waning => lit on the left.
  function svg(fraction, waxing) {
    var lit = Math.max(0, Math.min(1, fraction));
    var s = '<svg viewBox="0 0 100 100" role="img" aria-hidden="true">';
    s += '<circle cx="' + CX + '" cy="' + CY + '" r="47" fill="var(--phase-dark)"/>';
    if (lit > 0.001) {
      s += '<circle cx="' + CX + '" cy="' + CY + '" r="46" fill="var(--phase-light)"/>';
      if (lit < 0.999) {
        var d = distForFraction(lit);
        var scx = waxing ? (CX - d) : (CX + d);
        s += '<circle cx="' + scx.toFixed(2) + '" cy="' + CY + '" r="46" fill="var(--phase-dark)"/>';
      }
    }
    s += '<circle cx="' + CX + '" cy="' + CY + '" r="47" fill="none" stroke="var(--hair-strong)" stroke-width="1"/>';
    s += '</svg>';
    return s;
  }

  // Build the canonical 8-phase cycle strip into [data-phase-row].
  function buildPhaseRow(el) {
    var phases = [
      [0.0, true, "new"], [0.18, true, "waxing crescent"],
      [0.5, true, "first quarter"], [0.82, true, "waxing gibbous"],
      [1.0, true, "full"], [0.82, false, "waning gibbous"],
      [0.5, false, "last quarter"], [0.18, false, "waning crescent"]
    ];
    var html = "";
    for (var i = 0; i < phases.length; i++) {
      html += '<span class="moon" title="' + phases[i][2] + '">' + svg(phases[i][0], phases[i][1]) + '</span>';
    }
    html += '<span class="cap folio">the contract, one cycle</span>';
    el.innerHTML = html;
  }

  // Build a single badge [data-moon="fraction,waxing"].
  function buildBadges(root) {
    var nodes = (root || document).querySelectorAll("[data-moon]");
    for (var i = 0; i < nodes.length; i++) {
      var p = nodes[i].getAttribute("data-moon").split(",");
      nodes[i].innerHTML = svg(parseFloat(p[0]), p[1] === "true");
    }
  }

  function init() {
    var rows = document.querySelectorAll("[data-phase-row]");
    for (var i = 0; i < rows.length; i++) buildPhaseRow(rows[i]);
    buildBadges(document);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else { init(); }

  window.MoonPhase = { svg: svg, buildPhaseRow: buildPhaseRow };
})();
