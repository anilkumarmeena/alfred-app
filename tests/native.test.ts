import { describe, expect, it } from "vitest";
import { bindNative, levelTap, nativeAudio, type NativeAudio, type NativePage } from "../web-hook/native";

// A stand-in for the JarvisAudio plugin: records calls, and lets a test fire its events.
function fakePlugin(over: Partial<NativeAudio> = {}) {
  const listeners = new Map<string, ((e: any) => void)[]>();
  const calls: [string, any][] = [];
  const plugin: NativeAudio = {
    async start(o) { calls.push(["start", o]); fire("connection", { state: "connected" }); return { connection: "connected", muted: !!o.muted }; },
    async stop() { calls.push(["stop", null]); },
    async setMuted(o) { calls.push(["setMuted", o]); return { muted: o.muted }; },
    async sendText(o) { calls.push(["sendText", o]); },
    async getStatus() { return { connection: "disconnected", muted: false, interrupted: false }; },
    addListener(event, fn) { listeners.set(event, [...(listeners.get(event) || []), fn]); return { remove() {} }; },
    ...over,
  };
  function fire(event: string, e: any) { for (const fn of listeners.get(event) || []) fn(e); }
  return { plugin, calls, fire };
}

// A page that writes down what it was told.
function fakePage() {
  const log: string[] = [];
  const state = { link: "off", agent: "idle", connected: false, live: false, muted: false, paused: "", quality: null as string | null,
    lines: new Map<string, string>(), ended: [] as (string | undefined)[], unauthorized: [] as string[] };
  const page: NativePage = {
    setLink: (v) => { state.link = v; },
    setState: (s) => { state.agent = s; log.push(s); },
    setConnected: (v) => { state.connected = v; },
    setLive: (v) => { state.live = v; },
    setMuted: (v) => { state.muted = v; },
    setPaused: (v) => { state.paused = v; },
    setQuality: (q) => { state.quality = q; },
    line: (id, who, text) => { state.lines.set(id, `${who}: ${text}`); },
    ended: (m) => { state.ended.push(m); state.connected = false; state.live = false; },
    unauthorized: (m) => { state.unauthorized.push(m); },
  };
  return { page, state, log };
}

describe("nativeAudio", () => {
  it("is null in a browser and the plugin in the app", () => {
    expect(nativeAudio({})).toBeNull();
    expect(nativeAudio({ Capacitor: { isNativePlatform: () => false, Plugins: { JarvisAudio: {} } } })).toBeNull();
    const JarvisAudio = {};
    expect(nativeAudio({ Capacitor: { isNativePlatform: () => true, Plugins: { JarvisAudio } } })).toBe(JarvisAudio);
  });
});

describe("bindNative", () => {
  it("connects with the passcode and the page's origin, and follows the agent", async () => {
    const { plugin, calls, fire } = fakePlugin(), { page, state, log } = fakePage();
    const s = bindNative(plugin, page, "https://mac.ts.net");
    await s.connect({ passcode: "123456" });
    expect(calls[0]).toEqual(["start", { serverUrl: "https://mac.ts.net", passcode: "123456", muted: false, speakerOff: false }]);
    expect(state).toMatchObject({ link: "on", connected: true, live: true, agent: "initializing" });
    expect(log).toEqual(["connecting", "initializing"]);  // the event and start() resolving count once
    fire("agentState", { state: "speaking" });
    expect(state.agent).toBe("speaking");
    expect(s.connected()).toBe(true);
  });

  it("shows reconnecting, then listening again", async () => {
    const { plugin, fire } = fakePlugin(), { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    fire("agentState", { state: "listening" });
    fire("connection", { state: "reconnecting", reason: "network", attempt: 1, retryIn: 1000 });
    expect(state).toMatchObject({ link: "linking", agent: "reconnecting", connected: true });
    fire("connection", { state: "connected" });
    expect(state).toMatchObject({ link: "on", agent: "listening" });
  });

  it("follows earphone mutes and captions", async () => {
    const { plugin, fire } = fakePlugin(), { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    fire("mute", { muted: true, source: "earphone" });
    expect(state.muted).toBe(true);
    expect(s.muted()).toBe(true);
    fire("transcript", { id: "seg1", speaker: "jarvis", text: "Good", final: false });
    fire("transcript", { id: "seg1", speaker: "jarvis", text: "Good evening", final: true });
    fire("transcript", { id: "seg2", speaker: "you", text: "Hi", final: true });
    expect([...state.lines.values()]).toEqual(["jarvis: Good evening", "you: Hi"]);
    fire("interruption", { state: "began" });
    expect(state.paused).toBe("recovering");
    fire("interruption", { state: "ended" });
    expect(state.paused).toBe("");
  });

  it("asks for the passcode again when it's refused", async () => {
    const { plugin } = fakePlugin({ start: () => Promise.reject(Object.assign(new Error("Wrong passcode."), { code: "UNAUTHORIZED" })) });
    const { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "bad" });
    expect(state.unauthorized).toEqual(["Wrong passcode."]);
    expect(state.ended).toEqual([]);
    expect(s.connected()).toBe(false);
  });

  it("says why a session ended, but not after a hang-up", async () => {
    const { plugin, fire } = fakePlugin(), { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    fire("connection", { state: "disconnected", reason: "agentLeft", message: "JARVIS ended the session." });
    expect(state.ended).toEqual(["JARVIS ended the session."]);
    await s.connect({ passcode: "1" });
    await s.hangup();
    expect(state.ended).toEqual(["JARVIS ended the session.", undefined]);
  });

  it("starts a muted session for a typed message", async () => {
    const { plugin, calls } = fakePlugin(), { page } = fakePage();
    const s = bindNative(plugin, page);
    await s.sendText("what's on my list?", "123456");
    expect(calls.map((c) => c[0])).toEqual(["start", "sendText"]);
    expect(calls[0]![1].muted).toBe(true);
    expect(calls[1]![1]).toEqual({ text: "what's on my list?" });
  });

  it("adopts a session that's already running", async () => {
    const { plugin } = fakePlugin({ getStatus: async () => ({ connection: "connected", agent: "thinking", muted: true, interrupted: false, startedAt: 5 }) });
    const { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.adopt();
    expect(state).toMatchObject({ connected: true, live: true, muted: true, agent: "thinking" });
    expect(s.connected()).toBe(true);
  });

  it("resyncs from the plugin: a stale Mic paused or mute is put right", async () => {
    let status = { connection: "connected", agent: "listening", muted: false, interrupted: true };
    const { plugin, fire } = fakePlugin({ getStatus: async () => status });
    const { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    fire("interruption", { state: "began" });
    fire("mute", { muted: true, source: "earphone" });
    expect(state).toMatchObject({ paused: "recovering", muted: true });
    // The call ended and the user unmuted while the page was off screen, and it missed the events.
    status = { ...status, interrupted: false, muted: false };
    await s.adopt();
    expect(state).toMatchObject({ paused: "", muted: false, agent: "listening", connected: true });
    expect(s.muted()).toBe(false);
  });

  it("shows the plugin's mute when a mute is refused", async () => {
    const { plugin } = fakePlugin({
      setMuted: () => Promise.reject(Object.assign(new Error("The microphone couldn't start."), { code: "NO_MICROPHONE" })),
      getStatus: async () => ({ connection: "connected", muted: true, interrupted: false }),
    });
    const { page, state } = fakePage();
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    await s.setMuted(false);
    expect(state.muted).toBe(true);
    expect(s.muted()).toBe(true);
  });

  it("ends a session that ended while the page wasn't looking, but not one still starting", async () => {
    let finish!: () => void;
    const { plugin } = fakePlugin({
      start: () => new Promise((resolve) => { finish = () => resolve({ connection: "connected" }); }),
      getStatus: async () => ({ connection: "disconnected", muted: false, interrupted: false }),
    });
    const { page, state } = fakePage();
    const s = bindNative(plugin, page);
    const starting = s.connect({ passcode: "1" });
    await s.adopt();
    expect(state.ended).toEqual([]);
    expect(s.connected()).toBe(true);
    finish(); await starting;
    await s.adopt();
    expect(state.ended).toEqual(["Connection lost. Tap the core to reconnect."]);
    expect(s.connected()).toBe(false);
  });

  it("keeps the latest voice levels", async () => {
    const { plugin, fire } = fakePlugin(), { page } = fakePage();
    const s = bindNative(plugin, page);
    fire("levels", { mic: 0.4, agent: 0.1 });
    expect(s.levels()).toEqual({ mic: 0.4, agent: 0.1 });
  });

  it("switches the speaker: asked for at the start, through the plugin, and followed when a call changes it", async () => {
    const { plugin, calls, fire } = fakePlugin({
      async setSpeaker(o) { calls.push(["setSpeaker", o]); return { off: o.off }; },
    });
    const { page } = fakePage(), speaker: boolean[] = [];
    page.setSpeakerOff = (v) => speaker.push(v);
    const s = bindNative(plugin, page);
    expect(s.canSilence).toBe(true);
    await s.setSpeakerOff(true);  // no session yet: the page keeps the choice
    expect(calls).toEqual([]);
    await s.sendText("hi", "1", true);
    expect(calls[0]![1].speakerOff).toBe(true);  // silent from the greeting on
    await s.setSpeakerOff(false);
    expect(calls.at(-1)).toEqual(["setSpeaker", { off: false }]);
    fire("speaker", { off: true, source: "call" });
    expect(speaker).toEqual([false, true]);
  });

  it("offers the mic and speaker back after a call, and passes on the answer", async () => {
    const { plugin, calls, fire } = fakePlugin({
      async restoreAfterCall(o) { calls.push(["restoreAfterCall", o]); },
      getStatus: async () => ({ connection: "connected", muted: true, interrupted: false, speakerOff: true, afterCall: { muted: false, speakerOff: false } }),
    });
    const { page } = fakePage(), offers: unknown[] = [];
    page.setAfterCall = (was) => offers.push(was);
    const s = bindNative(plugin, page);
    await s.connect({ passcode: "1" });
    fire("call", { state: "ended", restore: { muted: false, speakerOff: true } });
    expect(offers.at(-1)).toEqual({ muted: false, speakerOff: true });
    await s.restoreAfterCall(true);
    expect(offers.at(-1)).toBeNull();
    expect(calls.at(-1)).toEqual(["restoreAfterCall", { restore: true }]);
    await s.adopt();  // missed while off screen
    expect(offers.at(-1)).toEqual({ muted: false, speakerOff: false });
  });

  it("leaves the speaker alone with a plugin that can't switch it", async () => {
    const { plugin, calls } = fakePlugin(), { page } = fakePage();
    const s = bindNative(plugin, page);
    expect(s.canSilence).toBe(false);
    await s.connect({ passcode: "1" });
    await s.setSpeakerOff(true);
    expect(calls.map((c) => c[0])).toEqual(["start"]);
  });
});

describe("levelTap", () => {
  it("draws nothing for silence and more for louder", () => {
    let level = 0;
    const t = levelTap(() => level);
    t.an.getByteFrequencyData(t.freq);
    expect(Math.max(...t.freq)).toBe(0);
    level = 0.5;
    t.an.getByteFrequencyData(t.freq);
    expect(Math.max(...t.freq)).toBeGreaterThan(100);
  });
});
