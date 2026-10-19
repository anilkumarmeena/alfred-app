import type { PermissionState, PluginListenerHandle } from "@capacitor/core";

// Runs Alfred's voice session natively (LiveKit connection, mic, voice, earphone button in Swift/Kotlin) so it keeps
// going in the background or with the screen locked, where the page is suspended. The page starts and ends the
// session and follows it through the events below.

/** The agent's lk.agent.state attribute. */
export type AgentState = "initializing" | "idle" | "listening" | "thinking" | "speaking";

/**
 * - `connecting`: first token fetch or room join.
 * - `connected`: in the room, audio flowing.
 * - `reconnecting`: network dropped; LiveKit or the plugin recovers it for as long as the session is wanted
 *   (`attempt` and `retryIn` set when the plugin rejoins with a fresh token).
 * - `disconnected`: session over; `reason` says why.
 */
export type ConnectionState = "connecting" | "connected" | "reconnecting" | "disconnected";

/** `network` comes with `reconnecting`; the rest end the session. */
export type EndReason =
  | "hangup"  // stop(), or ended from the notification
  | "agentLeft"  // Alfred ended the session
  | "unauthorized"  // passcode refused
  | "rateLimited"  // too many wrong passcodes
  | "network"  // lost, being recovered
  | "server"  // the Alfred server refused or closed the connection
  | "microphone";  // no mic permission, or the mic couldn't start

/** "system": the mic couldn't start, or the room muted the track (server, or LiveKit after a mic failure); show it
 * muted. "call": a phone call came in. */
export type MuteSource = "user" | "earphone" | "system" | "call";

export interface StartOptions {
  /** Page origin, e.g. https://mac.tailnet.ts.net. Defaults to the app's saved server URL. */
  serverUrl?: string;
  /** Same passcode the page sends to /api/token; kept in memory only, for background reconnects. */
  passcode: string;
  /** Sent to /api/token as `device` so logs/web.log can tell the phone apart. Defaults to iphone or android. */
  device?: string;
  /** Join muted (the page does this when a typed message starts the session). */
  muted?: boolean;
  /** Join with the speaker off: text-only replies, greeting included (see `setSpeaker`). */
  speakerOff?: boolean;
}

/** Mic and speaker state when a phone call came in; the page offers to restore it afterwards. */
export interface BeforeCall {
  muted: boolean;
  speakerOff: boolean;
}

export interface SessionStatus {
  connection: ConnectionState;
  /** Unset until the agent reports one. */
  agent?: AgentState;
  /** The mic track follows this: muted sends nothing, even after a reconnect or a call. */
  muted: boolean;
  /** Speaker off: Alfred replies only in text. */
  speakerOff?: boolean;
  /** After a phone call that turned mic and speaker off: their state before it, until the page calls
   * `restoreAfterCall` or the user changes either. */
  afterCall?: BeforeCall;
  /**
   * Something else holds the mic (phone call, Siri); it comes back on its own. Interruption ends aren't always
   * reported, so it's also cleared when the app comes on screen or the user unmutes: on iOS when iOS hands the audio
   * back (or the server hears the mic), on Android when no call is ringing or active. The page re-reads it when shown.
   */
  interrupted: boolean;
  /** Session start, ms since the epoch. */
  startedAt?: number;
  /** Audio route in use, e.g. "AirPods Pro" or "Speaker". */
  route?: string;
  /** iOS only: active and preferred Mic Mode. */
  micMode?: MicModeEvent;
}

/**
 * iOS Mic Mode. `preferred` is the user's Control Center choice; `active` is what processes the mic now (differs when
 * the route can't do the preferred one). Apps can't set it: the plugin opens Apple's picker once per launch when a
 * session's mic goes live without Voice Isolation. The page draws its Mic pill from these and opens the picker with
 * `showMicModes()`.
 */
export type MicMode = "standard" | "voiceIsolation" | "wideSpectrum" | "other";

export interface MicModeEvent {
  active: MicMode;
  preferred: MicMode;
}

export interface ConnectionEvent {
  state: ConnectionState;
  reason?: EndReason;
  /** Sentence for the page to show. */
  message?: string;
  /** Reconnect attempt number, from 1. */
  attempt?: number;
  /** Ms until the next attempt. */
  retryIn?: number;
}

export interface MuteEvent {
  muted: boolean;
  source: MuteSource;
}

/** One caption, re-sent in full as it grows: replace the line with the same `id`. */
export interface TranscriptEvent {
  id: string;
  speaker: "you" | "alfred";
  text: string;
  final: boolean;
}

export interface SpeakerEvent {
  off: boolean;
  source: "user" | "call";
}

/**
 * A phone call began (mutes the mic, turns the speaker off) or the last one ended. iOS also counts other apps' CallKit
 * calls (FaceTime, WhatsApp…); Android counts the phone's own calls (ringing, dialling or active). On "ended",
 * `restore` is set when the mic or speaker was on before the call: offer it back.
 */
export interface CallEvent {
  state: "began" | "ended";
  restore?: BeforeCall;
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

/** Voice levels 0–1, about 10 Hz while the app is on screen, for the reactor. */
export interface LevelsEvent {
  mic: number;
  agent: number;
}

export interface AlfredAudioPermissionStatus {
  microphone: PermissionState;
  /**
   * Alfred alerts (heartbeat, background tasks): APNs on iOS, FCM on Android, registered (asking the first time) when
   * a session starts. On Android 13+ also covers the session's own notification.
   */
  notifications: PermissionState;
}

export interface AlfredAudioPlugin {
  /**
   * Connects and starts the mic; resolves once connected. Rejects with UNAUTHORIZED, RATE_LIMITED, NO_MICROPHONE or
   * SERVER. Then registers for Alfred notifications (/api/push/native): APNs on iOS, FCM on Android (only in builds
   * with a google-services.json).
   */
  start(options: StartOptions): Promise<SessionStatus>;
  /** Ends the session and stops the mic. */
  stop(): Promise<void>;
  /**
   * Applies at once (while reconnecting, as soon as the room is back). On iOS, unmuting during an interruption
   * reclaims the audio, which ends an interruption iOS failed to end.
   */
  setMuted(options: { muted: boolean }): Promise<{ muted: boolean }>;
  toggleMute(): Promise<{ muted: boolean }>;
  /**
   * Speaker off (meeting, crowd, call): Alfred still hears mic and typed messages but replies only in text (transcript
   * events). The `alfred.speaker` participant attribute stops the agent speaking at all, and its track plays at
   * volume 0 so a reply already under way stops at once. No chime either.
   */
  setSpeaker(options: { off: boolean }): Promise<{ off: boolean }>;
  /** Answers the after-call offer; `restore` puts mic and speaker back as in `afterCall`. */
  restoreAfterCall(options: { restore: boolean }): Promise<void>;
  /** Sends a typed message on lk.chat, queued until the agent is listening (as the page does). */
  sendText(options: { text: string }): Promise<void>;
  getStatus(): Promise<SessionStatus>;
  /** iOS only. Android rejects it as unavailable (no Mic Mode an app can read). */
  getMicMode(): Promise<MicModeEvent>;
  /** iOS only: opens Apple's Mic Mode picker (Standard, Voice Isolation, Wide Spectrum). Android rejects it. */
  showMicModes(): Promise<void>;

  /** Saved server URL, and whether it's the build-time default. */
  getServerUrl(): Promise<{ url: string | null; fromBuild: boolean }>;
  /** Normalises (assumes https://), saves, and loads the page from it. Rejects with INVALID_URL. */
  setServerUrl(options: { url: string }): Promise<{ url: string }>;
  /** Forgets the saved URL and shows the first-run page. */
  clearServerUrl(): Promise<void>;

  checkPermissions(): Promise<AlfredAudioPermissionStatus>;
  requestPermissions(): Promise<AlfredAudioPermissionStatus>;

  addListener(event: "connection", fn: (e: ConnectionEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "agentState", fn: (e: { state: AgentState }) => void): Promise<PluginListenerHandle>;
  addListener(event: "mute", fn: (e: MuteEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "transcript", fn: (e: TranscriptEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "interruption", fn: (e: InterruptionEvent) => void): Promise<PluginListenerHandle>;
  /** Switched by the page or by a phone call. */
  addListener(event: "speaker", fn: (e: SpeakerEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "call", fn: (e: CallEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "route", fn: (e: RouteEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "quality", fn: (e: QualityEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: "levels", fn: (e: LevelsEvent) => void): Promise<PluginListenerHandle>;
  /** iOS only: Mic Mode changed (Control Center pick, or route change). */
  addListener(event: "micMode", fn: (e: MicModeEvent) => void): Promise<PluginListenerHandle>;
  removeAllListeners(): Promise<void>;
}
