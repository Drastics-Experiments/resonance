(function applyCachedResonanceTheme() {
  const fallback = "midnight";
  const themes = new Set([fallback, "ocean", "forest", "sunset"]);
  let theme = fallback;
  try {
    const cached = localStorage.getItem("resonance.theme");
    if (themes.has(cached)) theme = cached;
  } catch {
    // A blocked cache must never prevent the renderer from starting.
  }
  document.documentElement.dataset.theme = theme;
})();
