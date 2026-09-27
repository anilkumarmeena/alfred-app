// The JARVIS app's native voice session, for the web page: copy this file to the jarvis repo as
// web/src/lib/native.ts (see web-hook/README.md for the rest of the change).
//
// In the iOS and Android apps the JarvisAudio plugin runs the LiveKit session natively, so the mic keeps going
// in the background and the earphone button mutes it. The page then doesn't open a Room of its own: it asks the
// plugin to start, stop, mute and send text, and follows the plugin's events. In a browser nativeAudio() is null
// and nothing here runs. No imports: Capacitor's bridge puts the plugin on window.Capacitor.

type Handle = { remove(): Promise<void> | void };
type Listener = (e: any) => void;

/** The part of the JarvisAudio plugin the page uses (the full API is in jarvis-app's packages/jarvis-audio). */
export interface NativeAudio {
  start(o: { serverUrl?: string; passcode: string; device?: string; muted?: boolean }): Promise<unknown>;
  stop(): Promise<void>;
  setMuted(o: { muted: boolean }): Promise<{ muted: boolean }>;
  sendText(o: { text: string }): Promise<void>;
  getStatus(): Promise<{ connection: string; agent?: string; muted: boolean; interrupted: boolean; startedAt?: number }>;
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
  /** Picks up a session the plugin is already running, e.g. after the page reloaded. */
  adopt(): Promise<void>;
}

export function bindNative(plugin: NativeAudio, page: NativePage, origin = globalThis.location?.origin): NativeSession {
  let muted = false, live = false, agentKnown = false, last = "disconnected";
  const connected = () => last !== "disconnected";
  const levels = { mic: 0, agent: 0 };

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

  async function connect({ passcode, muted: startMuted = false }: { passcode: string; muted?: boolean }) {
    if (connected()) return;
    up("connecting");
    muted = startMuted; page.setMuted(startMuted);
    try {
      const s: any = await plugin.start({ serverUrl: origin, passcode, muted: startMuted });
      up(s?.connection || "connected", s?.startedAt);
    } catch (e: any) {
      const code = e?.code, message = e?.message || String(e);
      down(code === "UNAUTHORIZED" ? "unauthorized" : "server", message);
    }
  }

  return {
    connected,
    muted: () => muted,
    connect,
    async hangup() { await plugin.stop(); if (connected()) down("hangup"); },
    async setMuted(m) {
      if (!connected()) return;
      try { muted = (await plugin.setMuted({ muted: m })).muted; page.setMuted(muted); } catch {}
    },
    async sendText(text, passcode) {
      if (!connected()) await connect({ passcode, muted: true });
      if (connected()) await plugin.sendText({ text });
    },
    levels: () => levels,
    async adopt() {
      const s = await plugin.getStatus().catch(() => null);
      if (!s || s.connection === "disconnected") return;
      agentKnown = !!s.agent;
      muted = s.muted; page.setMuted(s.muted);
      up(s.connection, s.startedAt);
      if (s.agent && s.connection === "connected") page.setState(s.agent);
      if (s.interrupted) page.setPaused("recovering");
    },
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
