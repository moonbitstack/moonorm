// moondb · shared runtime — the theme twin and the at-top scroll thumb (docs.md)
(function () {
  "use strict";
  var root = document.documentElement;
  var KEY = "moondb-theme";

  function paint() {
    var theme = root.getAttribute("data-theme") || "light";
    var btns = document.querySelectorAll("#theme-toggle [data-set-theme]");
    for (var i = 0; i < btns.length; i++) {
      var on = btns[i].getAttribute("data-set-theme") === theme;
      btns[i].classList.toggle("on", on);
      btns[i].setAttribute("aria-pressed", on ? "true" : "false");
    }
  }

  function apply(theme, remember) {
    root.setAttribute("data-theme", theme);
    if (remember) { try { localStorage.setItem(KEY, theme); } catch (e) {} }
    paint();
  }

  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  if (!saved) {
    saved = (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches)
      ? "dark" : "light";
  }
  apply(saved, false);

  var group = document.getElementById("theme-toggle");
  if (group) {
    group.addEventListener("click", function (e) {
      var b = e.target.closest ? e.target.closest("[data-set-theme]") : null;
      if (b) apply(b.getAttribute("data-set-theme"), true);
    });
  }
  // kept for keyboard shortcuts and older markup
  window.toggleTheme = function () {
    apply(root.getAttribute("data-theme") === "dark" ? "light" : "dark", true);
  };

  // ---- at-top: the thumb is invisible at the very top, present once you scroll ----
  function sync() { root.classList.toggle("at-top", window.scrollY <= 0); }
  window.addEventListener("scroll", sync, { passive: true });
  sync();
})();
