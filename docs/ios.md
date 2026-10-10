<div align="center">

<img src="assets/logo.svg" width="72" alt="">

# 🍎 iOS

**How the Swift plugin (`packages/jarvis-audio/ios`) keeps a JARVIS session alive on the iPhone.**

[🏠 Home](../README.md) · [🧱 Architecture](architecture.md) · **🍎 iOS** · [🤖 Android](android.md) · [🔨 Build & test](build.md) · [📲 Install](install.md) · [🔗 JARVIS side](jarvis-side.md) · [🌐 Web hook](../web-hook/README.md) · [🔔 Push hook](../server-hook/README.md)

</div>

---

<table>
<tr>
<td width="33%" valign="top">

**[🔉 Audio](#-audio-session-and-engine)**<br>
Voice-chat session, background audio, mute without the iOS sound.

</td>
<td width="33%" valign="top">

**[🎧 AirPods](#-airpods-stem-press)**<br>
Press to Mute on the stem, and why the opt-in is repeated.

</td>
<td width="33%" valign="top">

**[🔇 Speaker off](#-speaker-off)**<br>
Replies only in the transcript.

</td>
</tr>
<tr>
<td width="33%" valign="top">

**[📞 Phone calls](#-phone-calls)**<br>
Mic muted and speaker off for a call, offered back after.

</td>
<td width="33%" valign="top">

**[📱 Live Activity](#-live-activity)**<br>
Lock screen, Dynamic Island and Apple Watch.

</td>
<td width="33%" valign="top">

**[🎤 Voice Isolation](#-voice-isolation)**<br>
Opening Apple's Mic Mode picker for you.

</td>
</tr>
<tr>
<td width="33%" valign="top">

**[🔄 Interruptions](#-interruptions-and-mic-sync)**<br>
"Mic paused", route changes, the mic track following the mute.

</td>
<td width="33%" valign="top">

**[📶 Reconnects](#-reconnects)**<br>
Fresh token and rejoin, for as long as the session is wanted.

</td>
<td width="33%" valign="top">

**[🔔 Notifications](#-notifications)**<br>
APNs alerts with the app closed.

</td>
</tr>
</table>

## 🔉 Audio session and engine

- **`AVAudioSession`** is `.playAndRecord`, mode `.voiceChat`, with Bluetooth HFP and A2DP, AirPlay, and the
  **speaker rather than the earpiece**.
- **`UIBackgroundModes` has `audio`**, and the session stays active for as long as the session is wanted.
- LiveKit's automatic session handling is **off**, so `AudioRouting.swift` is the only place that sets it up.
- LiveKit's audio engine is **`AVAudioEngine` with Apple's voice processing** (echo cancellation).
- **Mute uses its `inputMixer` mode**, so the engine keeps running: no iOS mute sound, and the app isn't suspended.
- **"Recording always prepared"** keeps the engine running between rooms too, so a reconnect in the background
  isn't suspended while it waits.

### 🚫 No Now Playing

The app takes no `MPRemoteCommandCenter` commands, so **iOS shows no media card for it**. That card always keeps
dimmed ⏮ ⏭ slots an app can't remove, and doubled up with the Live Activity.

> [!NOTE]
> The cost: the play/pause button of **wired EarPods and other Bluetooth headsets goes to the last media app**, not
> JARVIS. AirPods use the stem press below.

## 🎧 AirPods stem press

`AirPodsMute.swift`. On AirPods, **iOS 17's mute gesture mutes the app's input itself** and reports it with
`AVAudioApplication.inputMuteStateChangeNotification`.

| | Step | What happens |
|:-:|---|---|
| 1️⃣ | **Opt in** | Adding an observer for that notification opts the app into Press to Mute |
| 2️⃣ | **iOS marks sessions** | Each audio session the app has at that moment gets `PrefersBluetoothAccessoryMuting` |
| 3️⃣ | **Press accepted** | Only on a marked session that's recording |
| 4️⃣ | **Re-opt in** | `AirPodsMute.optIn` runs again once the mic is on, or the room is joined muted |

- A session created later **starts unmarked**, and the press gets "Cannot control mic with AirPods". That's why the
  observer is added when the plugin loads **and again** once the mic is on. With no session it's ignored.
- The plugin **follows iOS's state**, and tells iOS about every mute from the screen too with
  `AVAudioApplication.setInputMuted`, dropping the notification that echoes it back.
- Each notification is logged (subsystem `com.anil.jarvis`, category `mute`) with its value, iOS's mute state and
  the input route: `BluetoothHFP` for AirPods, `MicrophoneBuiltIn` for the phone.

## 🔇 Speaker off

`setSpeaker`, `start({ speakerOff })`: **JARVIS replies only in the transcript.**

- The plugin asks for it in `/api/token`'s request (`speaker: "off"`), so **the greeting is silent too**.
- During a session it changes it with its `jarvis.speaker` participant attribute; the agent then makes **no speech
  at all**.
- The agent's track also plays at **volume 0**, so a reply already being spoken stops at once.
- The Live Activity's mute plays no chime.

## 📞 Phone calls

`CallWatch.swift`, with `CallQuiet` in the core.

- **`CXCallObserver`** sees a call ringing, dialling or on, including FaceTime and other CallKit apps.
- The plugin **mutes the mic and turns the speaker off before iOS even interrupts the audio**.
- When the last call ends it sends a **`call` event** with what they were before (also in
  `getStatus().afterCall`), and the page offers to turn them back on.
- **`restoreAfterCall({ restore })`** is the answer. Changing either meanwhile closes the offer.

Android does both too: see [🤖 Android](android.md#-phone-calls).

## 📱 Live Activity

`ios/App/App/SessionActivity.swift`, drawn by the **`JarvisWidget`** extension. During a session the **lock
screen, the Dynamic Island and the Apple Watch Smart Stack** show:

- **JARVIS** and what it's doing: Listening, Muted, Speaking, Thinking, Connecting…, or Mic paused for a call
  (`SessionSummary` in the core),
- the session's running time,
- **Mute/Unmute** and **Hang Up** buttons. Tapping elsewhere opens the app.

Mute plays the same falling or rising chime as the page.

| | Detail |
|:-:|---|
| ⌚ | The watch has its own small layout (`supplementalActivityFamilies`), so **the extension needs iOS 18** |
| 👆 | A button tapped on the watch runs on the iPhone |
| 🔀 | The plugin hands the app the summary through `SessionControls` |
| 📄 | `ios/App/Shared/JarvisActivity.swift`, in both targets, holds the data and the buttons' intents |
| 🎚️ | Mute asks for a state (`SetMutedIntent(muted:)`), **not a toggle** |

- The plugin can't own the Activity itself: ActivityKit's types must be compiled into the extension too.
- The buttons' `LiveActivityIntent`s run in the app's process.
- Why not a toggle: **a tap on the watch reaches the iPhone twice**, and a toggle would undo itself.

**When it goes away**

- It ends with the session, and when the app is **quit from the app switcher** (`applicationWillTerminate`; iOS
  leaves a quit app's Live Activities up).
- After a crash it's cleared on the next launch.
- One swiped away stays away until the next session.
- Logged under category `liveactivity`.

## 🎤 Voice Isolation

`MicMode.swift`. iOS's Mic Modes (Standard, **Voice Isolation**, Wide Spectrum) run inside Apple's voice
processing, which the `.voiceChat` session and LiveKit's engine already use, so **Control Center offers Mic Mode
for JARVIS while the mic is on.**

> [!NOTE]
> **Apps can't set the mode.** Even in the iOS 27 SDK, `AVCaptureDevice.preferredMicrophoneMode` and
> `activeMicrophoneMode` are read-only.

So the app does the next best thing:

- The **first time in each launch** that a session's mic goes live and Voice Isolation isn't the chosen mode, it
  **opens Apple's picker itself** (`AVCaptureDevice.showSystemUserInterface(.microphoneModes)`).
- That's about **1.5 seconds after the mic starts**, and only with the app on screen.
- Once Voice Isolation is picked, iOS remembers it for the app and the picker stays shut.
- Both properties are watched with KVO. The page gets `micMode` events, the mode in `getStatus()`, `getMicMode()`
  and `showMicModes()`, and draws its own **Mic: …** pill from them during a session. The app draws no UI over the
  page.
- Each change, and the voice-processing state at mic start, is logged (subsystem `com.anil.jarvis`, category
  `micmode`).

## 🔄 Interruptions and mic sync

- **A call or Siri pauses the mic** ("Mic paused"). When it ends, the session is reactivated.
- iOS doesn't promise to report every interruption's end, so **"Mic paused" is also cleared** when:
  - iOS hands the audio back as the app comes on screen,
  - the user taps to unmute,
  - the server hears the mic (LiveKit's speaking updates include this phone).
- **Route changes** (AirPods in or out) go to the page as `route` events.
- **A media services reset rejoins.**

**The mic track follows the mute** (`MicSync` in the core):

- After every mute, reconnect and interruption, the plugin switches the track to match, so a mute made while
  reconnecting or during a call **really stops the mic**.
- If the room says otherwise (the track unmuted, or the server hearing it, while muted), it's **muted again**.
- A track the room mutes itself shows as muted on the page.

## 📶 Reconnects

- **LiveKit resumes short drops itself.**
- If the room is lost, the plugin fetches **a fresh token and rejoins**, for as long as the session is wanted:

| Attempt | 1 | 2 | 3 | 4 | 5 | 6 onwards |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Wait** | 1 s | 2 s | 4 s | 8 s | 15 s | every 30 s |

- It **retries straight away** when `NWPathMonitor` sees the network come back.
- It stops **only for a refused passcode**.

## 🔔 Notifications

`PushNotifications.swift`. **Heartbeat alerts** and **background tasks that finish, fail or have a question** come
through APNs, so they show with the app closed.

**1. Register** — when a session starts, the app asks for permission (the first time) and gets its APNs device
token.

**2. Post the token** — to `/api/push/native`, with the passcode, the APNs environment and the bundle id. The
environment comes from the build's provisioning profile: `development` for Xcode installs.

**3. Open on tap** — a tapped notification opens its page, e.g. `/?task=3`, **on the saved server only**.

> [!IMPORTANT]
> Needs the jarvis side in [🔔 Push hook](../server-hook/README.md), and a **paid developer team**: a Personal Team
> can't sign push.

## 🔧 Settings

**Settings → JARVIS** (`ios/App/App/Settings.bundle`) has the server address.

---

<div align="center">

[← 🧱 Architecture](architecture.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [🤖 Android →](android.md)

</div>
