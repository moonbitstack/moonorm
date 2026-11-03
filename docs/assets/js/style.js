// The guide's writing-style switch: annotated (the default), functional, class.
// The choice is persisted and applied to every `.variants .variant` group, so the
// whole page reads in one style at a time. Everything is wrapped in try so a browser
// that blocks storage simply falls back to the default.
const KEY = "moonorm-style";
const root = document.documentElement;
const buttons = Array.from(document.querySelectorAll("[data-set-style]"));

function applyStyle(style) {
  root.setAttribute("data-style", style);
  for (const el of document.querySelectorAll(".variants .variant")) {
    el.hidden = el.getAttribute("data-style") !== style;
  }
  for (const b of buttons) {
    b.setAttribute(
      "aria-pressed",
      b.getAttribute("data-set-style") === style ? "true" : "false",
    );
  }
  try {
    localStorage.setItem(KEY, style);
  } catch (e) {
    /* storage may be blocked; the page still switches */
  }
}

for (const b of buttons) {
  b.addEventListener("click", () => applyStyle(b.getAttribute("data-set-style")));
}

let saved = "annotated";
try {
  saved = localStorage.getItem(KEY) || "annotated";
} catch (e) {
  /* keep the default */
}
applyStyle(saved);
