// The page scroll bar shows while the page moves and while the pointer is at
// the right edge, and hides a moment after both stop.
const root = document.documentElement;
let idle = 0;
let near = false;
const hideSoon = () => {
  clearTimeout(idle);
  idle = setTimeout(() => near || root.classList.remove("scrolling"), 1200);
};
const show = () => {
  root.classList.add("scrolling");
  hideSoon();
};
addEventListener("scroll", show, { passive: true });
addEventListener("pointermove", (e) => {
  const was = near;
  near = e.pointerType === "mouse" && e.clientX >= root.clientWidth - 24;
  if (near) root.classList.add("scrolling");
  else if (was) hideSoon();
}, { passive: true });
root.addEventListener("pointerleave", () => {
  near = false;
  hideSoon();
});
