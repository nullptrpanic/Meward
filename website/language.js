(() => {
  const requested = new URLSearchParams(location.search).get("lang");
  const preference = requested || (location.hash === "#chinese" ? "zh" : navigator.language);
  const language = /^zh\b/i.test(preference) ? "zh" : "en";
  for (const section of document.querySelectorAll("main[data-language]")) {
    section.hidden = section.dataset.language !== language;
    if (!section.hidden) {
      document.documentElement.lang = section.lang;
      document.title = section.dataset.title;
    }
  }
})();
