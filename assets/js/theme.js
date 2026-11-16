// Loaded synchronously in the head so the saved theme applies before first paint.
(() => {
  const syncPressed = (theme) => {
    document.querySelectorAll("[data-phx-theme]").forEach((btn) => {
      btn.setAttribute("aria-pressed", btn.dataset.phxTheme === theme ? "true" : "false");
    });
  };
  const currentTheme = () =>
    localStorage.getItem("phx:theme") || "system";
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
    syncPressed(theme);
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(currentTheme());
  } else {
    syncPressed(currentTheme());
  }
  document.addEventListener("DOMContentLoaded", () => syncPressed(currentTheme()));
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));

  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
