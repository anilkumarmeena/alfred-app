import type { CapacitorConfig } from "@capacitor/cli";

// The app loads the live JARVIS page from the Mac, so web/ changes need no app rebuild. First match wins:
//   1. the address saved in the app (first-run page, iOS Settings → JARVIS, or JarvisAudio.setServerUrl)
//   2. JARVIS_SERVER_URL at `npx cap sync`, baked in as server.url
//   3. neither: the bundled first-run page in shell/ asks for it
// MainViewController (iOS) and MainActivity (Android) apply 1 over 2 at launch.
const serverUrl = process.env.JARVIS_SERVER_URL?.trim() || undefined;

const config: CapacitorConfig = {
  appId: "com.anil.jarvis",
  appName: "JARVIS",
  webDir: "shell",
  backgroundColor: "#04070c",
  server: {
    url: serverUrl,
    // Shown when the Mac can't be reached. Its jarvis-app:// links are handled natively by the plugin, so they work
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
