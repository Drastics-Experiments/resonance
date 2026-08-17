(function bootstrapResonanceRenderer() {
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

  let qualityStylesheet = document.querySelector("link[data-resonance-ui-quality]");
  if (!qualityStylesheet) {
    qualityStylesheet = document.createElement("link");
    qualityStylesheet.rel = "stylesheet";
    qualityStylesheet.href = "ui-quality.css";
    qualityStylesheet.dataset.resonanceUiQuality = "";
    document.head.append(qualityStylesheet);
  }

  const loadQualityLayer = () => {
    // Move the already-requested stylesheet after feature CSS so guardrails win the cascade.
    document.head.append(qualityStylesheet);
    return import("./ui-quality.js").catch((error) => {
      console.warn("Resonance UI quality layer did not load", error);
    });
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadQualityLayer, { once: true });
  } else {
    void loadQualityLayer();
  }
})();
