<div align="center">

<img src="assets/logo.svg" width="72" alt="">

# 🤖 Android

**The same features as iOS, built from Android's own pieces in the Kotlin plugin (`packages/alfred-audio/android`).**

[🏠 Home](../README.md) · [🧱 Architecture](architecture.md) · [🍎 iOS](ios.md) · **🤖 Android** · [🔨 Build & test](build.md) · [📲 Install](install.md) · [🤝 Contributing](../CONTRIBUTING.md)

</div>

---

<details>
<summary><b>📑 On this page</b></summary>

- [iOS and Android side by side](#-ios-and-android-side-by-side)
- [Keeping the mic alive](#-keeping-the-mic-alive)
- [Audio](#-audio)
- [The session notification](#-the-session-notification)
- [Headset buttons](#-headset-buttons)
- [Interruptions](#-interruptions)
- [Speaker off](#-speaker-off)
- [Phone calls](#-phone-calls)
- [Mic sync and reconnects](#-mic-sync-and-reconnects)
- [Notifications](#-notifications)

</details>

## 🔁 iOS and Android side by side

| iOS | Android |
|---|---|
| `UIBackgroundModes` audio | `VoiceService`, a foreground service of type `microphone` |
| Live Activity (lock screen, Dynamic Island, Watch) | The session's **call-style notification**; a Live Update on Android 16 |
| AirPods stem press | Headset buttons through a `MediaSession` |
| APNs push | Firebase Cloud Messaging push |
| Settings → Alfred | Long-press the app icon → **Change server** |
| CallKit's `CXCallObserver` | `AudioManager`'s mode: the phone's own calls |
| Mic Modes (Voice Isolation) | None: Android has no Mic Mode an app can read or offer |

## 🎤 Keeping the mic alive

- **`VoiceService`** is a foreground service of type `microphone`. It runs for as long as the session is wanted, so
  **the mic works with the screen off**.
- **Swiping the app away ends the session**, and the notification goes with it.
- After a crash, the notification goes with the process.

## 🔉 Audio

- LiveKit's **`AudioSwitchHandler`** sets communication mode, takes audio focus and routes to, in order:
  **Bluetooth headset → wired headset → speaker**.
- The voice input uses the phone's own echo cancellation and noise suppression.

## 📱 The session notification

`VoiceService.kt` is **Android's Live Activity**. It shows:

- **Alfred** and what it's doing: Listening, Muted, Speaking, Thinking, Connecting…, or Mic paused for a call
  (`SessionSummary` in the core, the same rules as iOS),
- the session's running time,
- **Mute/Unmute** and **Hang Up**. Tapping elsewhere opens the app.

| | Version / behaviour | What it does |
|:-:|---|---|
| 📞 | **Android 12+** | A `CallStyle` notification: lock screen and status bar show an ongoing call |
| 🏷️ | **Android 16** | Asks to be a **Live Update** (`POST_PROMOTED_NOTIFICATIONS`) |
| 🎚️ | **Mute** | Asks for a state, not a toggle, and plays the falling or rising chime |
| 🚫 | **No media card** | No `MediaStyle`, for the same reason iOS has no Now Playing |
| ⌚ | **Wear OS** | Doesn't mirror ongoing notifications, so it isn't on a watch |

- With `CallStyle`, Alfred is a call the user left running.
- A Live Update sits at the top of the lock screen and shows as a chip in the status bar.

## 🎧 Headset buttons

The service's **`MediaSession`** takes headset presses (the wired hook, Bluetooth play/pause) and **toggles the
mute with the chime**.

## 🔄 Interruptions

- A **transient loss of audio focus** (a phone call) pauses the mic until focus comes back.
- Android doesn't promise to give focus back every time. So **"Mic paused" is also cleared** when the app comes on
  screen, or the user taps to unmute, **if no phone call is ringing or going on** (`AudioManager.getMode()`,
  `MicSync` in the core).

## 🔇 Speaker off

`setSpeaker`, `start({ speakerOff })` **works as on iOS**:

- `speaker: "off"` in the token request,
- then the `alfred.speaker` participant attribute,
- the agent's track at volume 0, and no chime.

## 📞 Phone calls

`CallWatch.kt`, with `CallQuiet` in the core. A call **mutes the mic and turns the speaker off**, then offers them
back when it ends (the `call` event, `getStatus().afterCall`, `restoreAfterCall`), as on iOS.

- A call is detected from **`AudioManager`'s mode** (ringing, dialling or in a call), which **needs no permission**.
  Reading the phone state would need `READ_PHONE_STATE`.
- Android 12+ reports each mode change; before that it's checked on every audio focus change, and whenever the
  app comes on screen or the user unmutes.
- **Starting a session during a call** works as on iOS: it joins **muted with the speaker off**, offered back when
  the call ends, and shows **Mic paused**, since a phone call holds the audio. Typing and captions still work.
- **When the call ends** the app takes the audio back at once, rather than waiting for the audio focus to return.
  A session started during the call was refused the focus, so its audio handler is restarted to ask again.

> [!NOTE]
> Unlike iOS's CallKit, this **doesn't see other apps' internet calls** (WhatsApp, Meet), which use the same
> communication mode as Alfred. Their audio focus still pauses the mic ("Mic paused").

## 📶 Mic sync and reconnects

**The mic track follows the mute** (`MicSync`), and **reconnects** work as on iOS
([🍎 iOS → Reconnects](ios.md#-reconnects)), with `ConnectivityManager` for network changes.

## 🔔 Notifications

`PushNotifications.kt` and `AlfredMessagingService.kt`. **Heartbeat alerts** and **background tasks that finish,
fail or have a question** come through FCM, so they show with the app closed.

**1. Register** — when a session starts, the app gets its FCM token. It asks for notification permission the
first time, with the mic.

**2. Post the token** — to `/api/push/native`, with the passcode, `"service": "fcm"` and its package name.

**3. Show the alert** — the Alfred computer sends **data messages**, which the app shows itself in an **Alerts** channel. A newer
push with the same tag replaces the older one.

**4. Open on tap** — a tapped notification opens its page, e.g. `/?task=3`, **on the saved server only**.

> [!IMPORTANT]
> Needs a **Firebase project**: `android/app/google-services.json` in the app (git-ignored), and that project's
> service account on the Alfred computer. See [📲 Install → Android notifications](install.md#-android-notifications-firebase).
> An app built without the file works the same, just with no alerts, and logs that once.

---

<div align="center">

[← 🍎 iOS](ios.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [🔨 Build & test →](build.md)

</div>
