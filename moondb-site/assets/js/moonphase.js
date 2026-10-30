// moondb · moon-phase renderer — the only recurring motif.
//
// A phase is not two overlapping discs: the terminator is a half-ellipse whose
// half-width follows the illuminated fraction k. For k in [0,0.5) the lit part
// is a crescent hugging the right limb; at k = 0.5 the terminator is a straight
// chord; for k > 0.5 the lit part is a gibbous body spilling past the centre and
// reaching the left limb at k = 1.
//
//   path = right semicircle  +  ellipse arc (rx = r·|2k−1|) back to the top
//
// Ink is what the sun lights: a full moon is a solid disc, a new moon is a bare
// ring. Waning phases are the same path mirrored, so waxing always reads from
// the right limb inwards.
(function () {
  "use strict";

  var R = 44, CX = 50, CY = 50;

  function pathFor(k, waxing) {
    var rx = R * Math.abs(2 * k - 1);
    // k < 0.5: the arc bulges inward from the right limb -> crescent
    // k > 0.5: the arc bulges out to the left         -> gibbous
    var sweep = k < 0.5 ? 0 : 1;
    var d = "M" + CX + "," + (CY - R) +
            "A" + R + "," + R + " 0 0 1 " + CX + "," + (CY + R) +
            "A" + rx.toFixed(2) + "," + R + " 0 0 " + sweep + " " + CX + "," + (CY - R) + "Z";
    return { d: d, mirror: !waxing };
  }

  function nameOf(k, waxing) {
    if (k <= 0.02) return "new moon";
    if (k >= 0.98) return "full moon";
    if (Math.abs(k - 0.5) < 0.02) return waxing ? "first quarter" : "last quarter";
    if (k < 0.5) return waxing ? "waxing crescent" : "waning crescent";
    return waxing ? "waxing gibbous" : "waning gibbous";
  }

  // fraction in [0,1]; waxing => lit on the right limb.
  function svg(fraction, waxing) {
    var k = Math.max(0, Math.min(1, fraction));
    var p = pathFor(k, waxing);
    var label = nameOf(k, waxing);
    var s = '<svg viewBox="0 0 100 100" role="img" aria-label="' + label + '">';
    // the unlit body: a bare disc, hairline only
    s += '<circle cx="' + CX + '" cy="' + CY + '" r="' + R + '" fill="var(--moon-unlit)" stroke="var(--silver)" stroke-width="1"/>';
    s += '<g' + (p.mirror ? ' transform="translate(100,0) scale(-1,1)"' : "") + '>';
    s += '<path d="' + p.d + '" fill="var(--moon-lit)"/>';
    s += '</g>';
    // the limb is drawn last so a full moon keeps a crisp edge
    s += '<circle cx="' + CX + '" cy="' + CY + '" r="' + R + '" fill="none" stroke="var(--silver)" stroke-width="1"/>';
    s += '</svg>';
    return s;
  }

  // The canonical cycle: new -> waxing -> full -> waning -> back.
  var CYCLE = [
    [0.0, true], [0.22, true], [0.5, true], [0.8, true],
    [1.0, true], [0.8, false], [0.5, false], [0.22, false]
  ];

  function buildPhaseRow(el) {
    var html = "";
    for (var i = 0; i < CYCLE.length; i++) {
      var f = CYCLE[i][0], w = CYCLE[i][1];
      html += '<span class="moon" title="' + nameOf(f, w) + '">' + svg(f, w) + "</span>";
    }
    html += '<span class="cap folio">the contract, one cycle</span>';
    el.innerHTML = html;
  }

  // A single badge: <div class="moon" data-moon="fraction,waxing">.
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

  window.MoonPhase = { svg: svg, name: nameOf, buildPhaseRow: buildPhaseRow };
})();
