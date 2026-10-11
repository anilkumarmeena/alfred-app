// @ts-check
// Hands the server address to the plugin, which validates, saves and loads it. No imports: Capacitor's bridge
// exposes the plugin on window.Capacitor.
(function () {
  const form = /** @type {HTMLFormElement} */ (document.getElementById("setup"));
  const input = /** @type {HTMLInputElement} */ (document.getElementById("url"));
  const error = /** @type {HTMLElement} */ (document.getElementById("error"));
  const button = /** @type {HTMLButtonElement} */ (form.querySelector("button"));
  const plugin = /** @type {any} */ (window).Capacitor?.Plugins?.JarvisAudio;

  if (!plugin) {
    error.textContent = "This page only works inside the JARVIS app.";
    button.disabled = true;
    return;
  }

  plugin.getServerUrl().then((/** @type {{ url: string | null }} */ r) => {
    if (r.url && !input.value) input.value = r.url;
  }).catch(() => {});

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    error.textContent = "";
    button.disabled = true;
    try {
      await plugin.setServerUrl({ url: input.value });  // navigates away on success
    } catch (err) {
      error.textContent = /** @type {Error} */ (err).message || String(err);
      button.disabled = false;
    }
  });
})();
