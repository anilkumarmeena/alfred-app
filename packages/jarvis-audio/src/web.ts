import { WebPlugin } from "@capacitor/core";
import type { JarvisAudioPermissionStatus, JarvisAudioPlugin, SessionStatus } from "./definitions";

// In a browser the page runs its own LiveKit session, so there is nothing for the plugin to do. The page
// checks Capacitor.isNativePlatform() before using it; these only answer if something calls it anyway.
export class JarvisAudioWeb extends WebPlugin implements Pick<JarvisAudioPlugin,
  "start" | "stop" | "setMuted" | "toggleMute" | "sendText" | "getStatus" | "getServerUrl" | "setServerUrl"
  | "clearServerUrl" | "checkPermissions" | "requestPermissions"> {
  private none(): never { throw this.unavailable("JarvisAudio only runs in the iOS and Android apps."); }

  async start(): Promise<SessionStatus> { return this.none(); }
  async stop(): Promise<void> {}
  async setMuted(): Promise<{ muted: boolean }> { return this.none(); }
  async toggleMute(): Promise<{ muted: boolean }> { return this.none(); }
  async sendText(): Promise<void> { return this.none(); }
  async getStatus(): Promise<SessionStatus> { return { connection: "disconnected", muted: false, interrupted: false }; }
  async getServerUrl(): Promise<{ url: string | null; fromBuild: boolean }> { return { url: location.origin, fromBuild: false }; }
  async setServerUrl(): Promise<{ url: string }> { return this.none(); }
  async clearServerUrl(): Promise<void> { return this.none(); }
  async checkPermissions(): Promise<JarvisAudioPermissionStatus> { return { microphone: "prompt", notifications: "prompt" }; }
  async requestPermissions(): Promise<JarvisAudioPermissionStatus> { return this.none(); }
}
