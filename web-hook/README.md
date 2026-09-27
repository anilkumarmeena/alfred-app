# The web page's side of the app

The app loads the live JARVIS page from the Mac. For the native session to be used, the page needs one new
file and small changes in two others. Nothing on the server changes.

`jarvis-web.patch` is that change, made against the jarvis repo's `web/` as of 27 September 2026:

| File | Change |
|---|---|
| `web/src/lib/native.ts` | New, and identical to `native.ts` here. `nativeAudio()` finds the JarvisAudio plugin on `window.Capacitor` (null in a browser). `bindNative(plugin, page)` turns the plugin's events into page state and gives the page `connect`, `hangup`, `setMuted`, `sendText` and `adopt`. `levelTap()` feeds the reactor from the plugin's voice levels. It has no imports, and `tests/native.test.ts` here covers it. |
| `web/src/state/session.ts` | `const native = … bindNative(…)`, wired to the store. When `native` is set: `connect()` calls `native.connect()` instead of opening a `Room`; `hangup()`, `setMuted()` and `sendText()` go to the plugin; `activate()` toggles mute while a native session is up; `syncMute()` and `returned()` count a native session as a session; `reactorInput()` reads the level taps; `initSession()` gives `mediaKeys` no keepalive `<audio>`, skips the silence poll (the plugin owns the earphone button and Now Playing) and calls `native.adopt()` to pick up a session the app kept running while the page reloaded. In a browser `native` is null and every path is as before. |
| `web/src/state/push.ts` | In the app, `setupPush()` returns early (app web views have no Web Push, so the Enable notifications pill stays hidden), and `pushBlocked()` explains that if the bell is tapped. |

To apply it:

```sh
npm run check:web-patch            # here: applies it to a copy of ../jarvis/web, typechecks, runs its tests
cd ~/Desktop/projects/jarvis
git apply ~/Desktop/projects/jarvis-app/web-hook/jarvis-web.patch
make web-build                     # or make services-restart
```

If `web/` has moved on and the patch no longer applies, the table above is the whole change; `native.ts` is
the part that matters, and the `session.ts` hunks are one early return per entry point.

## What the page sees

In the app, `window.Capacitor.Plugins.JarvisAudio` (see `packages/jarvis-audio/src/definitions.ts`):

```ts
await JarvisAudio.start({ serverUrl: location.origin, passcode, muted });  // same passcode as /api/token
JarvisAudio.addListener("connection", ({ state, reason, message }) => …);  // connecting / connected / reconnecting / disconnected
JarvisAudio.addListener("agentState", ({ state }) => …);                   // lk.agent.state
JarvisAudio.addListener("mute", ({ muted, source }) => …);                 // source "earphone" for a button press
JarvisAudio.addListener("transcript", ({ id, speaker, text, final }) => …);// whole line so far, per lk.segment_id
JarvisAudio.addListener("interruption", ({ state }) => …);                 // a call took the mic, and gave it back
await JarvisAudio.setMuted({ muted: true });
await JarvisAudio.sendText({ text });                                       // lk.chat, held until the agent listens
await JarvisAudio.stop();
```
