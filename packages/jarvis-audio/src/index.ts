import { registerPlugin } from "@capacitor/core";
import type { JarvisAudioPlugin } from "./definitions";

export * from "./definitions";

/** `error.code` values the plugin rejects with. */
export const JarvisAudioError = {
  unauthorized: "UNAUTHORIZED",
  rateLimited: "RATE_LIMITED",
  noMicrophone: "NO_MICROPHONE",
  server: "SERVER",
  invalidUrl: "INVALID_URL",
  noServer: "NO_SERVER",
  notConnected: "NOT_CONNECTED",
} as const;

export const JarvisAudio = registerPlugin<JarvisAudioPlugin>("JarvisAudio", {
  web: () => import("./web").then((m) => new m.JarvisAudioWeb()),
});
