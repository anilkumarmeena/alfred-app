// The JARVIS app's native voice session, for the web page: copy this file to the jarvis repo as
// web/src/lib/native.ts (see web-hook/README.md for the rest of the change).
//
// In the iOS and Android apps the JarvisAudio plugin runs the LiveKit session natively, so the mic keeps going
// in the background and the earphone button mutes it. The page then doesn't open a Room of its own: it asks the
// plugin to start, stop, mute and send text, and follows the plugin's events. In a browser nativeAudio() is null
// and nothing here runs. No imports: Capacitor's bridge puts the plugin on window.Capacitor.

type Handle = { remove(): Promise<void> | void };
type Listener = (e: any) => void;

/** iOS's Mic Mode: `active` is processing the mic now, `preferred` is what the user picked in Control Center. */
export interface MicMode { active: string; preferred: string }

/** The part of the JarvisAudio plugin the page uses (the full API is in jarvis-app's packages/jarvis-audio). */
export interface NativeAudio {
  start(o: { serverUrl?: string; passcode: string; device?: string; muted?: boolean }): Promise<unknown>;
  stop(): Promise<void>;
  setMuted(o: { muted: boolean }): Promise<{ muted: boolean }>;
  sendText(o: { text: string }): Promise<void>;
  getStatus(): Promise<{ connection: string; agent?: string; muted: boolean; interrupted: boolean; startedAt?: number; micMode?: MicMode }>;
  showMicModes?(): Promise<void>;  // iOS only: Apple's Mic Mode picker
  addListener(event: string, fn: Listener): Promise<Handle> | Handle;
}

/** The plugin when running inside the JARVIS app, else null. */
export function nativeAudio(win: any = globalThis): NativeAudio | null {
  const cap = win?.Capacitor;
  if (!cap?.isNativePlatform?.()) return null;
  return cap.Plugins?.JarvisAudio ?? null;
}

/** What the session needs from the page: session.ts implements it with its store. */
export interface NativePage {
  setLink(v: "off" | "linking" | "on"): void;
  setState(s: string): void;  // an AgentState, or "connecting" / "reconnecting"
  setConnected(v: boolean): void;  // a session exists, live or still connecting
  setLive(v: boolean, startedAt?: number): void;  // connected with audio going
  setMuted(v: boolean): void;
  setPaused(v: "" | "recovering"): void;  // a call or Siri has the mic for now
  setQuality(q: string | null): void;
  line(id: string, who: "you" | "jarvis", text: string): void;  // a caption: replace the line with this id
  ended(message?: string): void;  // back to no session, saying why if it wasn't the user
  unauthorized(message: string): void;  // the passcode was refused: ask again
  setMicMode?(m: MicMode | null): void;  // iOS: the Mic Mode in use during a session, null without one
}

export interface NativeSession {
  /** A session exists (connecting, live or reconnecting). */
  connected(): boolean;
  muted(): boolean;
  connect(o: { passcode: string; muted?: boolean }): Promise<void>;
  hangup(): Promise<void>;
  setMuted(m: boolean): Promise<void>;
  /** Starts a muted session first if there's none, as the page does for typed messages. */
  sendText(text: string, passcode: string): Promise<void>;
  /** Voice levels from 0 to 1, for the reactor. */
  levels(): { mic: number; agent: number };
  /** Shows the plugin's state as it is now: a session it kept running while the page reloaded, or what changed
   * while the page was off screen, where its JavaScript is paused and events can be missed. */
  adopt(): Promise<void>;
  /** iOS: opens Apple's Mic Mode picker. */
  showMicModes(): void;
}

export function bindNative(plugin: NativeAudio, page: NativePage, origin = globalThis.location?.origin): NativeSession {
  let muted = false, live = false, agentKnown = false, last = "disconnected", starting = false;
  const connected = () => last !== "disconnected";
  const levels = { mic: 0, agent: 0 };
  const micMode = (m?: MicMode) => { if (m?.active) page.setMicMode?.({ active: m.active, preferred: m.preferred || m.active }); };

  // state is "connecting", "reconnecting" or "connected"
  function up(state: string, startedAt?: number) {
    if (state === last) return;  // start() resolving repeats the event that already came
    last = state;
    page.setConnected(true);
    page.setLink(state === "connected" ? "on" : "linking");
    if (state !== "connected") return page.setState(state);
    if (!live) { live = true; page.setLive(true, startedAt ?? Date.now()); }
    page.setState(agentKnown ? "listening" : "initializing");
  }

  function down(reason?: string, message?: string) {
    const was = connected();
    live = false; muted = false; agentKnown = false; last = "disconnected";
    levels.mic = levels.agent = 0;
    page.setMicMode?.(null);
    if (reason === "unauthorized") return page.unauthorized(message || "Wrong passcode.");
    if (was || message) page.ended(reason === "hangup" ? undefined : message || "Connection lost. Tap the core to reconnect.");
  }

  const on = (event: string, fn: Listener) => { plugin.addListener(event, fn); };
  on("connection", (e) => (e.state === "disconnected" ? down(e.reason, e.message) : up(e.state)));
  on("agentState", (e) => { agentKnown = true; if (connected()) page.setState(e.state); });
  on("mute", (e) => { muted = !!e.muted; page.setMuted(muted); });
  on("transcript", (e) => page.line(e.id, e.speaker === "you" ? "you" : "jarvis", e.text));
  on("interruption", (e) => page.setPaused(e.state === "began" ? "recovering" : ""));
  on("quality", (e) => page.setQuality(e.quality));
  on("levels", (e) => { levels.mic = +e.mic || 0; levels.agent = +e.agent || 0; });
  on("micMode", (e) => { if (connected()) micMode(e); });

  async function connect({ passcode, muted: startMuted = false }: { passcode: string; muted?: boolean }) {
    if (connected()) return;
    up("connecting");
    muted = startMuted; page.setMuted(startMuted);
    starting = true;
    try {
      const s: any = await plugin.start({ serverUrl: origin, passcode, muted: startMuted });
      micMode(s?.micMode);
      up(s?.connection || "connected", s?.startedAt);
    } catch (e: any) {
      const code = e?.code, message = e?.message || String(e);
      down(code === "UNAUTHORIZED" ? "unauthorized" : "server", message);
    } finally {
      starting = false;
    }
  }

  async function adopt() {
    const s = await plugin.getStatus().catch(() => null);
    if (!s) return;
    if (s.connection === "disconnected") {  // it ended while the page wasn't looking (not still starting)
      if (connected() && !starting) down("server");
      return;
    }
    if (s.agent) agentKnown = true;
    muted = s.muted; page.setMuted(s.muted);
    page.setPaused(s.interrupted ? "recovering" : "");  // "Mic paused" only while a call or Siri really has it
    micMode(s.micMode);
    up(s.connection, s.startedAt);
    if (s.agent && s.connection === "connected") page.setState(s.agent);
  }

  return {
    connected,
    muted: () => muted,
    connect,
    async hangup() { await plugin.stop(); if (connected()) down("hangup"); },
    async setMuted(m) {
      if (!connected()) return;
      // Refused (the mic couldn't start, or the session is gone): show what the plugin has, not what was asked.
      try { muted = (await plugin.setMuted({ muted: m })).muted; page.setMuted(muted); } catch { await adopt(); }
    },
    async sendText(text, passcode) {
      if (!connected()) await connect({ passcode, muted: true });
      if (connected()) await plugin.sendText({ text });
    },
    levels: () => levels,
    showMicModes() { plugin.showMicModes?.().catch(() => {}); },
    adopt,
  };
}

/** Something the reactor can read like an analyser Tap, drawn from a level: a soft spectrum that follows it. */
export function levelTap(level: () => number) {
  const freq = new Uint8Array(128);
  return {
    freq,
    an: {
      getByteFrequencyData(out: Uint8Array) {
        const v = Math.max(0, Math.min(1, level())), t = Date.now() / 180;
        for (let i = 0; i < out.length; i++) {
          const shape = Math.exp(-i / 18) * (0.75 + 0.25 * Math.sin(t + i * 0.7));
          out[i] = Math.round(255 * Math.min(1, v * 2.2) * shape);
        }
      },
    },
  };
}
