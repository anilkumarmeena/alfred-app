<div align="center">

<img src="../docs/assets/logo.svg" width="72" alt="">

# 🌐 Web hook

**The live JARVIS page's side of the app: three patches for the jarvis repo, and the plugin API the page calls.**

[🏠 Home](../README.md) · [🧱 Architecture](../docs/architecture.md) · [🍎 iOS](../docs/ios.md) · [🤖 Android](../docs/android.md) · [🔨 Build & test](../docs/build.md) · [📲 Install](../docs/install.md) · [🔗 JARVIS side](../docs/jarvis-side.md) · **🌐 Web hook** · [🔔 Push hook](../server-hook/README.md)

</div>

---

The app loads the live JARVIS page from the Mac. For the native session to be used, **the page needs one new file and
small changes in two others. Nothing on the server changes.**

<table>
<tr>
<td width="33%" valign="top">

**[📱 Native session](#-native-session)**<br>
`jarvis-web.patch`: the page drives the plugin. **Required.**

</td>
<td width="33%" valign="top">

**[🔧 Preferences](#-settings--preferences)**<br>
`jarvis-preferences.patch`: one page for how JARVIS behaves.

</td>
<td width="33%" valign="top">

**[🎤 Mic state sync](#-mic-state-sync)**<br>
`jarvis-mic-sync.patch`: no stale "Mic paused".

</td>
</tr>
</table>

> [!TIP]
> Each patch has a dry run, `npm run check:…`, that applies it to a **copy** of the jarvis repo, typechecks it and
> runs its tests. Run it before `git apply`.

## 📱 Native session

**`jarvis-web.patch`**, made against the jarvis repo's `web/` as of **27 September 2026**.

| File | Change |
|---|---|
| `web/src/lib/native.ts` | **New**, and identical to `native.ts` here |
| `web/src/state/session.ts` | Wires `bindNative(…)` to the store; each entry point defers to the plugin |
| `web/src/state/push.ts` | In the app, skips Web Push and explains why |

**`native.ts`**

- `nativeAudio()` finds the JarvisAudio plugin on `window.Capacitor` (null in a browser).
- `bindNative(plugin, page)` turns the plugin's events into page state and gives the page `connect`, `hangup`,
  `setMuted`, `sendText` and `adopt`.
- `levelTap()` feeds the reactor from the plugin's voice levels.
- It has no imports, and `tests/native.test.ts` here covers it.

**`session.ts`** — `const native = … bindNative(…)`, wired to the store. When `native` is set:

- `connect()` calls `native.connect()` instead of opening a `Room`,
- `hangup()`, `setMuted()` and `sendText()` go to the plugin,
- `activate()` toggles mute while a native session is up,
- `syncMute()` and `returned()` count a native session as a session,
- `reactorInput()` reads the level taps,
- `initSession()` gives `mediaKeys` no keepalive `<audio>`, skips the silence poll (the plugin owns the earphone
  button and Now Playing), and calls `native.adopt()` to pick up a session the app kept running while the page
  reloaded.

In a browser `native` is null and **every path is as before**.

**`push.ts`** — in the app, `setupPush()` returns early (app web views have no Web Push, so the Enable
notifications pill stays hidden), and `pushBlocked()` explains that if the bell is tapped.

**Apply it** (the jarvis repo next to this one):

```sh
npm run check:web-patch            # here: applies it to a copy of ../jarvis/web, typechecks, runs its tests
cd ../jarvis
git apply ../jarvis-app/web-hook/jarvis-web.patch
make web-build                     # or make services-restart
```

> [!NOTE]
> If `web/` has moved on and the patch no longer applies, **the table above is the whole change**. `native.ts` is the
> part that matters, and the `session.ts` hunks are one early return per entry point.

## 🔧 Settings → Preferences

**`jarvis-preferences.patch`**, made against the jarvis repo as of **8 October 2026**. It gathers the settings about
how JARVIS behaves onto one page, opened from a **Preferences** row at the top of Settings, and adds **do not
disturb** there.

| Preferences has | Was |
|---|---|
| **Do not disturb** | Only above the scheduled jobs in Tasks (still there), and by voice |
| **Voice** | Settings → Voice, plus a Voice Isolation row in the Settings list |
| **Background work** | Settings → System, under the services |

- **Do not disturb:** a switch (on until turned off, or off), **1 hour**, and **Until then** with a time. While it's
  on, the same buttons change its end.
- **Voice:** Voice Isolation (iPhone app only), JARVIS's voice, speed, phantom filter.
- **Background work:** background tasks at once, web browser on or off, browser window shown or hidden.
- Settings keeps Connections, Google accounts, Memory, Vocabulary, Skills, Approvals, About you, Notifications,
  System, Keyboard shortcuts and Lock.

| File | Change |
|---|---|
| `jarvis/panel.py` | New `hold_status` action: is do not disturb on? |
| `tests/test_panel.py` | The do not disturb test reads it before, during and after |
| `web/src/state/panel.ts` | Settings item `voice` becomes `prefs` |
| `web/src/components/panel/Settings.tsx` | The Preferences row and page |
| `web/src/components/icons.tsx`, `Overlays.tsx` | A switch icon for the row, and Preferences in ⌘K |
| `README.md`, `docs/architecture.md` | "Settings → Voice" / "→ System" become "Settings → Preferences" |

- **`hold_status`** answers `{"hold", "usage"}`, as `hold_on` and `hold_off` do, without asking the task runner as
  `tasks` does. The page already turned do not disturb on and off with `hold_on` and `hold_off`.
- **`panel.ts`:** `prefs` loads the preferences and `hold_status`; System no longer loads the preferences. The
  Settings list loads what its own lines show (system, connections, skills, preferences) once each.
- **`Settings.tsx`:** the row's line says when do not disturb is on, with an amber dot, else the voice. Voice
  Isolation and the System page's preferences move there. On a wide screen Settings opens on Preferences.

**Apply it:**

```sh
npm run check:preferences-patch    # here: applies it to a copy, typechecks, runs the web and panel tests
cd ../jarvis
git apply ../jarvis-app/web-hook/jarvis-preferences.patch
make services-restart              # rebuilds the page and restarts the web app (hold_status is new)
```

## 🎤 Mic state sync

**`jarvis-mic-sync.patch`**, made against the jarvis repo's `web/` as of **9 October 2026**. It fixes the page
showing "Mic paused" or Muted **while the app's mic was really live**.

- **The cause:** the page only followed the plugin's events, and missed any sent while iOS had the web view
  suspended, so a stale state stayed on screen.
- **The app's half** of the fix is in the plugin: the mic track always follows the mute, and a forgotten
  interruption is cleared. **This is the page's half.**

| File | Change |
|---|---|
| `web/src/lib/native.ts` | `adopt()` re-reads everything from `getStatus()`; a refused `setMuted` shows the real state |
| `web/src/state/session.ts` | `returned()` calls `native.adopt()`; tapping during "Mic paused" unmutes |
| `web/tests/native.test.ts` | Stale state put right, a refused mute, a session that ended unseen, one still starting |

- **`adopt()`** also clears "Mic paused" when the plugin isn't interrupted, and ends a session the plugin no longer
  has (not one still starting). It's the same `bindNative` as `native.ts` here.
- **`returned()`** runs when the page is back on screen.
- **Tapping the core during "Mic paused"** in the app unmutes, which asks the plugin for the mic back, rather than
  toggling to Muted.
- The tests cover a stale "Mic paused" and mute put right by `adopt()`.

**Apply it:**

```sh
npm run check:mic-sync-patch       # here: applies it to a copy, typechecks, runs the web tests
cd ../jarvis
git apply ../jarvis-app/web-hook/jarvis-mic-sync.patch
make web-build                     # the app loads the page live: no app rebuild for this half
```

## 🧩 What the page sees

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

---

<div align="center">

[← 🔗 JARVIS side](../docs/jarvis-side.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [🔔 Push hook →](../server-hook/README.md)

</div>
