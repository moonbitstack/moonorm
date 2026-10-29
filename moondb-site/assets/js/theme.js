// moondb · shared runtime — theme twin + at-top scrollbar (docs.md)
(function () {
  "use strict";
  var root = document.documentElement;
  var KEY = "moondb-theme";
  function apply(theme) {
    root.setAttribute("data-theme", theme);
    var btn = document.getElementById("theme-toggle");
    if (btn) btn.textContent = theme === "dark" ? "night" : "day";
  }
  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  if (!saved) {
    saved = (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light";
  }
  apply(saved);

  window.toggleTheme = function () {
    var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    apply(next);
    try { localStorage.setItem(KEY, next); } catch (e) {}
  };

  function sync() { root.classList.toggle("at-top", window.scrollY <= 0); }
  window.addEventListener("scroll", sync, { passive: true });
  sync();
})();
