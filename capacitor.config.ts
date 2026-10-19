import type { CapacitorConfig } from "@capacitor/cli";

// The app loads the live Alfred page from the Mac, so web/ changes need no app rebuild. First match wins:
//   1. the address saved in the app (first-run page, iOS Settings → Alfred, or AlfredAudio.setServerUrl)
//   2. ALFRED_SERVER_URL at `npx cap sync`, baked in as server.url
//   3. neither: the bundled first-run page in shell/ asks for it
// MainViewController (iOS) and MainActivity (Android) apply 1 over 2 at launch.
const serverUrl = (process.env.ALFRED_SERVER_URL || process.env.JARVIS_SERVER_URL)?.trim() || undefined;  // JARVIS_: its old name

// Kept from when Alfred was JARVIS, as they are: the bundle id and Android applicationId below (a new one would be a
// separate app, its settings and push sign-up lost), the plugin's JS name JarvisAudio and its jarvis.speaker attribute
// (what servers from before the rename look for), the saved settings' keys and Android's notification channel ids.
const config: CapacitorConfig = {
  appId: "com.anil.jarvis",
  appName: "Alfred",
  webDir: "shell",
  backgroundColor: "#04070c",
  server: {
    url: serverUrl,
    // Shown when the Mac can't be reached. Its alfred-app:// links are handled natively by the plugin, so they work
    // even where the page has no Capacitor bridge.
    errorPath: "error.html",
    androidScheme: "https",
    // Normally Tailscale Serve's HTTPS address; plain http is only for localhost development.
    cleartext: serverUrl?.startsWith("http://") ?? false,
    allowNavigation: ["*.ts.net"],
  },
  ios: {
    contentInset: "never",
  },
};

export default config;
