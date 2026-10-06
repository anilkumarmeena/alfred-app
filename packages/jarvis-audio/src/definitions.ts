import type { PermissionState, PluginListenerHandle } from "@capacitor/core";

// JarvisAudio runs JARVIS's voice session natively: the LiveKit connection, the mic, JARVIS's voice and the
// earphone button all live in Swift (iOS) or Kotlin (Android), so they keep going with the app in the
// background or the screen locked, where the web page itself is suspended. The page stays the UI: it
// starts and ends the session, and follows it through the events below.

/** What the agent says it's doing, from its lk.agent.state attribute. */
export type AgentState = "initializing" | "idle" | "listening" | "thinking" | "speaking";

/**
 * The connection, as the native side sees it.
 * - `connecting`: fetching a token or joining the room, the first time.
 * - `connected`: in the room with audio going.
 * - `reconnecting`: the network dropped; LiveKit or the plugin is bringing it back on its own, for as long
 *   as the session is wanted (with `attempt` and `retryIn` when the plugin is rejoining with a fresh token).
 * - `disconnected`: the session is over. `reason` says why.
 */
export type ConnectionState = "connecting" | "connected" | "reconnecting" | "disconnected";

/** Why the connection changed. `network` comes with `reconnecting`; the others end the session. */
export type EndReason =
  | "hangup"  // stop() was called, or the session was ended from the notification
  | "agentLeft"  // JARVIS ended the session
  | "unauthorized"  // the passcode was refused
  | "rateLimited"  // too many wrong passcodes
  | "network"  // lost, and being brought back
  | "server"  // the Mac refused or closed the connection
  | "microphone";  // no mic permission, or the mic couldn't start

/** Who changed the mute. */
export type MuteSource = "user" | "earphone" | "system";

export interface StartOptions {
  /** The page's origin, e.g. https://mac.tailnet.ts.net. Defaults to the app's saved server URL. */
  serverUrl?: string;
  /** The same passcode the page sends to /api/token. Kept in memory only, to reconnect in the background. */
  passcode: string;
  /** Sent to /api/token as `device`, so logs/web.log can tell the phone apart. Defaults to iphone or android. */
  device?: string;
  /** Join with the mic muted (the page does this when a typed message starts the session). */
  muted?: boolean;
}

export interface SessionStatus {
  connection: ConnectionState;
  /** Unset until the agent has said. */
  agent?: AgentState;
  muted: boolean;
  /** The mic is held by something else right now (a phone call, Siri): it comes back on its own. */
  interrupted: boolean;
  /** When the current session started, in ms since the epoch. */
  startedAt?: number;
  /** The audio route in use, e.g. "AirPods Pro" or "Speaker". */
  route?: string;
  /** iOS only: the Mic Mode in use and the one the user picked. */
  micMode?: MicModeEvent;
}

/**
 * iOS's Mic Mode for the app. `preferred` is what the user picked in Control Center; `active` is what's
 * processing the mic now, which differs when the route can't do the preferred one. Apps can't set it: the
 * plugin opens Apple's picker once per launch when a session's mic goes live without Voice Isolation. The page
 * draws its own Mic pill from these and opens the picker with `showMicModes()`.
 */
export type MicMode = "standard" | "voiceIsolation" | "wideSpectrum" | "other";

export interface MicModeEvent {
  active: MicMode;
  preferred: MicMode;
}

export interface ConnectionEvent {
  state: ConnectionState;
  reason?: EndReason;
  /** A sentence for the page to show. */
  message?: string;
  /** Which reconnect attempt this is, from 1. */
  attempt?: number;
  /** When the next attempt is due, in ms from now. */
  retryIn?: number;
}

export interface MuteEvent {
  muted: boolean;
  source: MuteSource;
}

/** One caption, re-sent in full as it grows: replace the line with the same `id`. */
export interface TranscriptEvent {
  id: string;
  speaker: "you" | "jarvis";
  text: string;
  final: boolean;
}

export interface InterruptionEvent {
  state: "began" | "ended";
}

export interface RouteEvent {
  /** e.g. "AirPods Pro", "Speaker", "Receiver", "Headphones". */
  output: string;
  input?: string;
  /** e.g. "newDevice", "oldDeviceUnavailable". */
  reason?: string;
}

export interface QualityEvent {
  quality: "excellent" | "good" | "poor" | "lost" | "unknown";
}

/** Voice levels, 0 to 1, about ten times a second while the app is on screen: for the reactor. */
export interface LevelsEvent {
  mic: number;
  agent: number;
}

export interface JarvisAudioPermissionStatus {
  microphone: PermissionState;
  /**
   * Android 13+: the ongoing-session notification. iOS: JARVIS's alerts (heartbeat, background tasks), which
   * the app registers for through APNs when a session starts, asking the first time.
   */
  notifications: PermissionState;
}

export interface JarvisAudioPlugin {
  /**
   * Connects to JARVIS and starts the mic. Resolves once connected; rejects with code UNAUTHORIZED, RATE_LIMITED,
   * NO_MICROPHONE or SERVER. On iOS it then registers the app for JARVIS's notifications (/api/push/native).
   */
  start(options: StartOptions): Promise<SessionStatus>;
  /** Ends the session and stops the mic. */
  stop(): Promise<void>;
  setMuted(options: { muted: boolean }): Promise<{ muted: boolean }>;
  toggleMute(): Promise<{ muted: boolean }>;
  /** Sends a typed message on lk.chat. Before the agent is listening it is queued, like the page does. */
  sendText(options: { text: string }): Promise<void>;
  getStatus(): Promise<SessionStatus>;
  /** iOS only: the current Mic Mode. */
  getMicMode(): Promise<MicModeEvent>;
  /** iOS only: opens Apple's Mic Mode picker (Standard, Voice Isolation, Wide Spectrum). */
  showMicModes(): Promise<void>;

  /** The saved server URL, and whether it's the build-time default. */
  getServerUrl(): Promise<{ url: string | null; fromBuild: boolean }>;
  /** Normalises (https:// is assumed), saves and loads the page from it. Rejects with code INVALID_URL. */
  setServerUrl(options: { url: string }): Promise<{ url: string }>;
  /** Forgets the saved URL and shows the first-run page. */
  clearServerUrl(): Promise<void>;

  checkPermissions(): Promise<JarvisAudioPermissionStatus>;
  requestPermissions(): Promise<JarvisAudioPermissionStatus>;

  addListener(event: "connection", fn: (e: ConnectionEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "agentState", fn: (e: { state: AgentState }) => void): Promise<PluginListenerHandle>;
  addListener(event: "mute", fn: (e: MuteEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "transcript", fn: (e: TranscriptEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "interruption", fn: (e: InterruptionEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "route", fn: (e: RouteEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "quality", fn: (e: QualityEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "levels", fn: (e: LevelsEvent) => void): Promise<PluginListenerHandle>;
  /** iOS only: the Mic Mode changed (picked in Control Center, or the route changed). */
  addListener(event: "micMode", fn: (e: MicModeEvent) => void): Promise<PluginListenerHandle>;
  removeAllListeners(): Promise<void>;
}
