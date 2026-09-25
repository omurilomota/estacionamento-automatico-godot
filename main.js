// Placeholder interactivity: smooth anchor scroll + F2 self-check.
// Every section below is a banca claim; the checklist verifies the
// workspace still proves it (no 404s, tasks files present).
(function () {
  document.querySelectorAll('a[href^="#"]').forEach(function (a) {
    a.addEventListener("click", function (ev) {
      var t = document.querySelector(a.getAttribute("href"));
      if (t) { ev.preventDefault(); t.scrollIntoView({ behavior: "smooth" }); }
    });
  });
})();
