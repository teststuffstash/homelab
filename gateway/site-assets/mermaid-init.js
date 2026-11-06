// Specs-site flowcharts (the oracle-fleet docs/javascripts/mermaid-init.js shape): render ```mermaid fences ourselves so node `click … href "#anchor"`
// links work (oracle-fleet#955). Material's native integration leaves Mermaid at securityLevel "strict",
// where click directives are inert, and gives no hook to change it — so mkdocs.yml emits the
// fences as <div class="mermaid-src"> (Material ignores that class) and this script, with the
// pinned Mermaid that scripts/specs-build.sh stages as javascripts/mermaid.min.js, renders them. Sources are
// our own committed spec text, so "loose" is the level the click feature needs, not a trust gap.
(function () {
  "use strict";
  var seq = 0;

  function theme() {
    var scheme = document.body && document.body.getAttribute("data-md-color-scheme");
    return scheme === "slate" ? "dark" : "default";
  }

  function render() {
    var nodes = document.querySelectorAll("div.mermaid-src:not([data-rendered])");
    if (!nodes.length || typeof mermaid === "undefined") return;
    mermaid.initialize({ startOnLoad: false, securityLevel: "loose", theme: theme() });
    nodes.forEach(function (el) {
      var src = el.textContent;
      el.setAttribute("data-rendered", "1");
      mermaid
        .render("mermaid-src-" + seq++, src)
        .then(function (out) {
          el.innerHTML = out.svg;
          el.classList.add("mermaid-done");
        })
        .catch(function (err) {
          el.classList.add("mermaid-error");
          console.error("mermaid render failed", err);
        });
    });
  }

  // Material's `document$` re-emits after every instant navigation; without it, run once.
  if (typeof document$ !== "undefined") document$.subscribe(render);
  else if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", render);
  else render();
})();
