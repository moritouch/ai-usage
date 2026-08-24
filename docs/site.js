(() => {
  "use strict";

  if (window.location.hostname.endsWith(".github.io")) {
    const target = new URL("https://moritouch.com/ai-usage");
    target.search = window.location.search;
    target.hash = window.location.hash;
    window.location.replace(target);
  }
})();
