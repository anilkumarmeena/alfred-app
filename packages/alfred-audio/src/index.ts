import { registerPlugin } from "@capacitor/core";
import type { AlfredAudioPlugin } from "./definitions";

export * from "./definitions";

/** `error.code` values the plugin rejects with. */
export const AlfredAudioError = {
  unauthorized: "UNAUTHORIZED",
  rateLimited: "RATE_LIMITED",
  noMicrophone: "NO_MICROPHONE",
  server: "SERVER",
  invalidUrl: "INVALID_URL",
  noServer: "NO_SERVER",
  notConnected: "NOT_CONNECTED",
} as const;

export const AlfredAudio = registerPlugin<AlfredAudioPlugin>("JarvisAudio", {
  web: () => import("./web").then((m) => new m.AlfredAudioWeb()),
});
