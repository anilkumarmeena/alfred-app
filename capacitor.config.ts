import type { CapacitorConfig } from "@capacitor/cli";

// The app loads the live JARVIS page from the Mac, so a change to web/ shows up without rebuilding the app.
// Where it loads it from, first match wins:
//   1. the address saved in the app (its first-run page, iOS Settings → JARVIS, or JarvisAudio.setServerUrl)
//   2. JARVIS_SERVER_URL when `npx cap sync` ran, baked in here as server.url
//   3. neither: the bundled first-run page in shell/ asks for it
// The native side (MainViewController on iOS, MainActivity on Android) applies 1 over 2 at launch.
const serverUrl = process.env.JARVIS_SERVER_URL?.trim() || undefined;

const config: CapacitorConfig = {
  appId: "com.anil.jarvis",
  appName: "JARVIS",
  webDir: "shell",
  backgroundColor: "#04070c",
  server: {
    url: serverUrl,
    // Shown when the Mac can't be reached. Its links (jarvis-app://retry, jarvis-app://setup) are handled
    // natively by the plugin, so they work even where the error page has no Capacitor bridge.
    errorPath: "error.html",
    androidScheme: "https",
    // Tailscale Serve's HTTPS address. Plain http is only for localhost while developing.
    cleartext: serverUrl?.startsWith("http://") ?? false,
    allowNavigation: ["*.ts.net"],
  },
  ios: {
    contentInset: "never",
  },
};

export default config;
