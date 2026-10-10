# JARVIS for iPhone and Android

The phone app for JARVIS, Anil's voice assistant, built with Capacitor. It shows the live JARVIS web page from
the Mac, so changes to the page in the jarvis repo show up without rebuilding the app. The voice session runs
in a native plugin, JarvisAudio, and not in the web view, so:

- the mic keeps listening with the screen locked or another app in front (a mobile browser or plain web view
  stops it),
- JARVIS's voice keeps playing in the background,
- the earphone button mutes and unmutes: the AirPods stem press on iOS 17+; on Android also a wired or
  Bluetooth headset's play/pause, and the notification's controls,
- on iPhone, a Live Activity on the lock screen, in the Dynamic Island and on Apple Watch shows what JARVIS is
  doing, with Mute/Unmute and Hang Up buttons; on Android, an ongoing-call notification does the same (a Live
  Update on Android 16),
- JARVIS's alerts (heartbeat, background tasks) arrive with the app closed: APNs on iPhone, Firebase Cloud
  Messaging on Android,
- phone calls, Siri, AirPods going in and out, and network drops are handled: the session comes back on its own.

## How it works

```
┌──────────── phone app (Capacitor) ─────────────┐            ┌──────────── Mac ─────────────┐
│ WKWebView / Android WebView                    │  HTTPS     │ jarvis.web :8787             │
│   the live page from https://<mac>.ts.net ─────┼──────────▶ │   /  /static/*  /api/token   │
│   (web/ in the jarvis repo, + lib/native.ts)   │ Tailscale  │                              │
│        │ JarvisAudio.start / setMuted / events │  Serve     │ LiveKit :7880 (/rtc)         │
│        ▼                                       │            │   room jarvis-xxxx           │
│ JarvisAudio plugin (Swift / Kotlin)            │  WebRTC    │     ▲                        │
│   LiveKit native SDK: mic → Opus, agent voice ─┼──────────▶ │     └─ agent.py              │
│   AVAudioSession / foreground service          │ UDP 7882   │        Whisper → Claude →    │
│   earphone button, interruptions, reconnects   │            │        Kokoro                │
└────────────────────────────────────────────────┘            └──────────────────────────────┘
```

**What the page does today** (read from the jarvis repo, not changed by this one). The page is served by
`jarvis/web.py` on `127.0.0.1:8787` and reached from the phone only through Tailscale Serve, at
`https://<mac-name>.<tailnet>.ts.net` (the Mac's own browsers use `http://localhost:8787`). It never streams
audio over a plain WebSocket: it POSTs `{"passcode", "device"}` to `/api/token`, gets back a LiveKit token for
a fresh room and a URL (`wss://<same host>`, which Tailscale Serve proxies at `/rtc` to LiveKit on port 7880),
and joins the room with `livekit-client`. The mic goes up as a WebRTC Opus track (48 kHz, echo cancellation,
noise suppression and auto gain on; media over UDP 7882), and JARVIS's voice (Kokoro, spoken by `agent.py`)
comes back as the agent's audio track. The agent's state is its `lk.agent.state` attribute, captions arrive as
text streams on `lk.transcription`, and typed messages go out on `lk.chat`. The passcode is the only auth: the
page keeps it in `localStorage` and sends it with every `/api/*` call; ten wrong ones in five minutes lock
everyone out for a while. Web Push uses a VAPID key from `/api/push/key`, a service worker at `/sw.js`, and
`/api/push/subscribe`, and only works in the Home Screen web app over HTTPS.

**What the app does.** The plugin speaks that same protocol natively, with LiveKit's own Swift and Android
SDKs: it fetches the token from `/api/token` with the passcode the page hands it, joins the room, publishes
the mic and plays the agent's track, reads `lk.agent.state` and `lk.transcription`, and sends `lk.chat`. The
native side owns the connection, because the web view's JavaScript is suspended in the background. The
page stays the UI: in the app it calls the plugin instead of opening its own `Room`, and follows the plugin's
events (`web-hook/`). Nothing changes on the Mac.

**Loading the page.** `server.url` in the Capacitor config points the web view at the Mac, and the bridge
works on the remote page, so the plugin is on `window.Capacitor.Plugins.JarvisAudio` there. The address is
set in the app, not baked in: at launch `MainViewController` (iOS) and `MainActivity` (Android) put the
saved address into Capacitor's config before the bridge starts. With no address saved, the app shows its one
bundled page, `shell/index.html`, which asks for it. If the Mac can't be reached, Capacitor shows
`shell/error.html`, with Try again and Change server.

### iOS (Swift, `packages/jarvis-audio/ios`)

- `AVAudioSession` is `.playAndRecord`, mode `.voiceChat`, with Bluetooth HFP and A2DP, AirPlay, and the
  speaker rather than the earpiece. `UIBackgroundModes` has `audio`, and the session stays active for as long
  as the session is wanted. LiveKit's automatic session handling is off, so `AudioRouting.swift` is the only
  place that sets it up.
- LiveKit's audio engine is `AVAudioEngine` with Apple's voice processing (echo cancellation). Mute uses its
  `inputMixer` mode, so the engine keeps running (no iOS mute sound, and the app isn't suspended). "Recording
  always prepared" mode keeps the engine running between rooms too, so a reconnect in the background isn't
  suspended while it waits.
- AirPods stem press (`AirPodsMute.swift`): on AirPods, iOS 17's mute gesture mutes the app's input itself and
  reports it with `AVAudioApplication.inputMuteStateChangeNotification`. Adding an observer for that notification
  is what opts the app into Press to Mute: iOS marks each audio session the app has at that moment
  (`PrefersBluetoothAccessoryMuting`), and a stem press is only accepted on a marked session that's recording. A
  session created later starts unmarked, and the press gets "Cannot control mic with AirPods". So the observer is
  added when the plugin loads and added again (`AirPodsMute.optIn`) once the mic is on, or the room is joined
  muted; with no session it's ignored. The plugin follows iOS's state, and tells iOS about every mute from the screen too with
  `AVAudioApplication.setInputMuted`, dropping the notification that echoes it back. Each notification is logged
  (subsystem `com.anil.jarvis`, category `mute`) with its value, iOS's mute state and the input route
  (`BluetoothHFP` for AirPods, `MicrophoneBuiltIn` for the phone).
- Speaker off (`setSpeaker`, `start({ speakerOff })`): JARVIS replies only in the transcript. The plugin asks for it
  in `/api/token`'s request (`speaker: "off"`), so the greeting is silent too, and changes it during a session with
  its `jarvis.speaker` participant attribute; the agent then makes no speech at all. The agent's track also plays at
  volume 0, so a reply already being spoken stops at once, and the Live Activity's mute plays no chime.
- Phone calls (`CallWatch.swift`, `CallQuiet` in the core): `CXCallObserver` sees a call ringing, dialling or on
  (FaceTime and other CallKit apps too), and the plugin mutes the mic and turns the speaker off before iOS even
  interrupts the audio. When the last call ends it sends a `call` event with what they were before (also in
  `getStatus().afterCall`), and the page offers to turn them back on; `restoreAfterCall({ restore })` is the answer.
  Changing either meanwhile closes the offer. Android does both too (below).
- No Now Playing: the app takes no `MPRemoteCommandCenter` commands, so iOS shows no media card for it (that
  card always keeps dimmed ⏮ ⏭ slots an app can't remove, and doubled up with the Live Activity). The cost: the
  play/pause button of wired EarPods and other Bluetooth headsets goes to the last media app, not JARVIS.
- Live Activity (`ios/App/App/SessionActivity.swift`, drawn by the `JarvisWidget` extension): during a session
  the lock screen, the Dynamic Island and the Apple Watch Smart Stack show **JARVIS**, what it's doing
  (Listening, Muted, Speaking, Thinking, Connecting…, Mic paused for a call; `SessionSummary` in the core), the
  session's running time, and **Mute/Unmute** and **Hang Up** buttons; tapping elsewhere opens the app. The
  watch gets its own small layout (`supplementalActivityFamilies`, so the extension needs iOS 18), and a button
  tapped there runs on the iPhone. Mute plays the same falling or rising chime as the page. The plugin hands
  the app the summary through `SessionControls` (it can't own the Activity itself, as ActivityKit's types must be
  compiled into the extension too). `ios/App/Shared/JarvisActivity.swift`, in both targets, has the activity's
  data and the buttons' `LiveActivityIntent`s, which run in the app's process. Mute asks for a state (`SetMutedIntent(muted:)`), not a toggle: a tap on the watch reaches the iPhone twice, and a toggle would undo itself. It ends with the session, and when
  the app is quit from the app switcher (`applicationWillTerminate`; iOS leaves a quit app's Live Activities
  up). After a crash it's cleared on the next launch. One swiped away stays away until the next session. Logged under category `liveactivity`.
- Voice Isolation (`MicMode.swift`): iOS's Mic Modes (Standard, Voice Isolation, Wide Spectrum) run inside
  Apple's voice processing, which the `.voiceChat` session and LiveKit's engine already use, so Control Center
  offers Mic Mode for JARVIS while the mic is on. Apps can't set the mode (even in the iOS 27 SDK,
  `AVCaptureDevice.preferredMicrophoneMode` and `activeMicrophoneMode` are read-only), so the app does the
  next best thing: the first time in each launch that a session's mic goes live and Voice Isolation isn't the
  chosen mode, it opens Apple's picker itself (`AVCaptureDevice.showSystemUserInterface(.microphoneModes)`),
  about 1.5 seconds after the mic starts and only with the app on screen. Once Voice Isolation is picked, iOS
  remembers it for the app and the picker stays shut. Both properties are watched with KVO; the page gets
  `micMode` events, the mode in `getStatus()`, `getMicMode()` and `showMicModes()`, and draws its own
  **Mic: …** pill from them during a session (the app draws no UI over the page). Each change and the voice-processing state at mic start are logged (subsystem
  `com.anil.jarvis`, category `micmode`).
- Interruptions: a call or Siri pauses the mic ("Mic paused"), and when it ends the session is reactivated.
  iOS doesn't promise to report every interruption's end, so a "Mic paused" is also cleared when iOS hands the
  audio back as the app comes on screen or the user taps to unmute, and when the server hears the mic (LiveKit's
  speaking updates include this phone). Route changes (AirPods in or out) go to the page as `route` events. A
  media services reset rejoins.
- The mic track follows the mute (`MicSync` in the core): after every mute, reconnect and interruption the plugin
  switches it to match, so a mute made while reconnecting or during a call really stops the mic, and if the room
  says otherwise (the track unmuted, or the server hearing it, while muted) it's muted again. A track the room
  mutes itself shows as muted on the page.
- Reconnects: LiveKit resumes short drops itself. If the room is lost, the plugin fetches a fresh token and
  rejoins, after 1, 2, 4, 8 and 15 seconds, then every 30, for as long as the session is wanted. It retries
  straight away when `NWPathMonitor` sees the network come back, and stops only for a refused passcode.
- Notifications (`PushNotifications.swift`): heartbeat alerts and background tasks that finish, fail or have a
  question come through APNs, so they show with the app closed. When a session starts, the app asks for
  permission (the first time), gets its APNs device token and posts it to `/api/push/native` with the
  passcode, the APNs environment (from the build's provisioning profile: `development` for Xcode installs)
  and the bundle id. Tapping a notification opens its page, e.g. `/?task=3`, on the saved server only. Needs
  the jarvis side in `server-hook/`, and a paid developer team (a Personal Team can't sign push).
- Settings → JARVIS (`ios/App/App/Settings.bundle`) has the server address.

### Android (Kotlin, `packages/jarvis-audio/android`)

The same features as iOS, with Android's own pieces:

| iOS | Android |
|---|---|
| `UIBackgroundModes` audio | `VoiceService`, a foreground service of type `microphone` |
| Live Activity (lock screen, Dynamic Island, Watch) | the session's **call-style notification**, a Live Update on Android 16 |
| AirPods stem press | headset buttons through a `MediaSession` |
| APNs push | Firebase Cloud Messaging push |
| Settings → JARVIS | long-press the app icon → **Change server** |
| CallKit's `CXCallObserver` (calls quiet JARVIS) | `AudioManager`'s mode: the phone's own calls |
| Mic Modes (Voice Isolation) | none: Android has no Mic Mode an app can read or offer |

- **Keeping the mic alive.** `VoiceService` is a foreground service of type `microphone`. It runs for as long as
  the session is wanted, so the mic works with the screen off. Swiping the app away ends the session, and the
  notification goes with it. After a crash, the notification goes with the process.
- **Audio.** LiveKit's `AudioSwitchHandler` sets communication mode, takes audio focus and routes to a Bluetooth
  headset, a wired headset or the speaker, in that order. The voice input uses the phone's own echo cancellation
  and noise suppression.
- **The session notification** (`VoiceService.kt`) is Android's Live Activity. It shows **JARVIS**, what it's
  doing (Listening, Muted, Speaking, Thinking, Connecting…, Mic paused for a call; `SessionSummary` in the core,
  the same rules as iOS), the session's running time, and **Mute/Unmute** and **Hang Up**. Tapping elsewhere
  opens the app.
  - On Android 12+ it's a `CallStyle` notification (JARVIS is a call the user left running), so the lock screen
    and status bar show it as an ongoing call.
  - On Android 16 it asks to be promoted to a **Live Update** (`POST_PROMOTED_NOTIFICATIONS`): it sits at the top
    of the lock screen and shows as a chip in the status bar.
  - As on iOS, Mute asks for a state, not a toggle, and plays the falling or rising chime.
  - There's no media card (no `MediaStyle`), for the same reason iOS has no Now Playing.
  - Wear OS doesn't mirror ongoing notifications, so unlike the iOS Live Activity it doesn't appear on a watch.
- **Headset buttons.** The service's `MediaSession` takes headset presses (the wired hook, Bluetooth
  play/pause) and toggles the mute with the chime.
- **Interruptions.** A transient loss of audio focus (a phone call) pauses the mic until focus comes back. Android
  doesn't promise to give focus back every time. So "Mic paused" is also cleared when the app comes on screen, or
  the user taps to unmute, if no phone call is ringing or going on (`AudioManager.getMode()`, `MicSync` in the
  core).
- **Speaker off** (`setSpeaker`, `start({ speakerOff })`) works as on iOS: `speaker: "off"` in the token request,
  then the `jarvis.speaker` participant attribute, the agent's track at volume 0, and no chime.
- **Phone calls** (`CallWatch.kt`, `CallQuiet` in the core) mute the mic and turn the speaker off, then offer them
  back when the call ends (the `call` event, `getStatus().afterCall`, `restoreAfterCall`), as on iOS.
  - A call is detected from `AudioManager`'s mode (ringing, dialling or in a call), which needs no permission:
    reading the phone state would need `READ_PHONE_STATE`. Android 12+ reports each mode change; before that it's
    checked on every audio focus change.
  - Unlike iOS's CallKit, this doesn't see other apps' internet calls (WhatsApp, Meet), which use the same
    communication mode as JARVIS. Their audio focus still pauses the mic ("Mic paused").
- **The mic track follows the mute** (`MicSync`), and **reconnects** work as on iOS, with `ConnectivityManager`
  for network changes.
- **Notifications** (`PushNotifications.kt`, `JarvisMessagingService.kt`): heartbeat alerts and background tasks
  that finish, fail or have a question come through FCM, so they show with the app closed.
  - When a session starts, the app gets its FCM token and posts it to `/api/push/native` with the passcode,
    `"service": "fcm"` and its package name. It asks for notification permission the first time, with the mic.
  - The Mac sends data messages, which the app shows itself in an **Alerts** channel. A newer push with the same
    tag replaces the older one.
  - Tapping a notification opens its page, e.g. `/?task=3`, on the saved server only.
  - Needs a Firebase project: `android/app/google-services.json` in the app (git-ignored), and that project's
    service account on the Mac. See [Android notifications](#android-notifications-firebase). An app built
    without the file works the same, just with no alerts, and logs that once.

### Layout

| Path | What |
|---|---|
| `capacitor.config.ts` | App id `com.anil.jarvis`, `webDir: shell`, optional build-time `server.url` from `JARVIS_SERVER_URL`, `errorPath`. |
| `shell/` | The bundled pages: first-run address prompt and the can't-reach-the-Mac page. |
| `packages/jarvis-audio/` | The plugin: `src/definitions.ts` (the TypeScript API), `ios/Sources/JarvisAudioPlugin` (Swift), `ios/JarvisAudioCore` (plain-Swift logic and its tests), `android/src/main/java/com/anil/jarvis/audio` (Kotlin; `core/` is the plain-Kotlin logic, tested in `android/src/test`). |
| `ios/`, `android/` | The native projects from `npx cap add`, with the changes below. |
| `web-hook/` | The page's side: `native.ts`, `jarvis-web.patch`, `jarvis-preferences.patch` and `jarvis-mic-sync.patch`, see [web-hook/README.md](web-hook/README.md). |
| `server-hook/` | The jarvis server's side of app notifications: `jarvis-native-push.patch` (APNs), see [server-hook/README.md](server-hook/README.md). |
| `tests/` | vitest tests for `web-hook/native.ts`. |
| `scripts/` | Test and build helpers (below). |

Changes to the generated projects: iOS 17 deployment target; `Info.plist` with the mic usage description,
`UIBackgroundModes` `audio`, `NSAllowsLocalNetworking` (plain http only for localhost and LAN addresses; the
real address is HTTPS) and a local network usage description; `MainViewController.swift` (set in
`Main.storyboard`) and `Settings.bundle`; `App.entitlements` with `aps-environment` (the Push Notifications
capability) and `AppDelegate.swift` setting up `PushNotifications` and passing on the APNs token. Android: `minSdk` 26, `compileSdk`/`targetSdk` 35 (Capacitor 7's),
JitPack in the repositories (LiveKit's audioswitch fork), `network_security_config.xml` allowing cleartext
only for `localhost`, `127.0.0.1` and `10.0.2.2`, the Change server shortcut, and `MainActivity`. The
plugin's manifest adds `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`, `POST_PROMOTED_NOTIFICATIONS`, `BLUETOOTH_CONNECT`,
`ACCESS_NETWORK_STATE`, the voice service and the Firebase messaging service. The app's `build.gradle` applies
the Google services plugin only when `google-services.json` is there.

## Changes needed on the JARVIS side

1. **Web (required):** apply `web-hook/jarvis-web.patch` to the jarvis repo, as described in
   [web-hook/README.md](web-hook/README.md), and rebuild the page (`make web-build`). Until then the app
   still works, but as a plain web view: the page opens its own LiveKit session, and the mic stops in the
   background.
2. **Server, for the voice session: none.** The app uses the existing `/api/token`, the existing passcode and
   the existing Tailscale Serve setup (`make tailscale-serve`). `logs/web.log` will show the phone as device
   `iphone` or `android`.
3. **Server, for notifications:** app web views have no Web Push, so the jarvis server's pushes, which were
   Web Push only, never reached the app. The app registers its own token and posts it to `/api/push/native`.
   - **iPhone (APNs):** the jarvis side is `server-hook/jarvis-native-push.patch`, plus an APNs auth key from the
     Apple Developer account. See [server-hook/README.md](server-hook/README.md). Until it's applied the app's
     token is refused with a 404 (logged in Xcode's console), and nothing else changes.
   - **Android (FCM):** the jarvis side is in the jarvis repo itself (`jarvis/notify/fcm.py`, commit `fcc5f99`),
     plus a Firebase service account. See [Android notifications](#android-notifications-firebase). Against a
     jarvis without it, the token is refused with a 400 (in `adb logcat -s JarvisAudio`), and nothing else
     changes.
4. **Settings → Preferences:** `web-hook/jarvis-preferences.patch` puts do not disturb, the voice settings
   (with Voice Isolation) and the background-work settings on one Preferences page, and adds the small
   `hold_status` panel action it reads do not disturb with. See [web-hook/README.md](web-hook/README.md#settings--preferences).
   Nothing in the app changes for it: apply it on the Mac and `make services-restart`.
5. **Mic state sync:** `web-hook/jarvis-mic-sync.patch` has the page re-read the plugin's state whenever it comes
   back on screen (events sent while the web view was suspended can be lost), show the plugin's mute when a mute
   is refused, and ask for the mic back when the core is tapped during "Mic paused". See
   [web-hook/README.md](web-hook/README.md#mic-state-sync). Apply it on the Mac and `make web-build`.

## Build

Needs Node 20+ (Capacitor 7; Capacitor 8 needs Node 22), Xcode 16.3+ for the LiveKit Swift package, and Android
Studio with JDK 21 (its bundled JBR is fine).

```sh
cd ~/Desktop/projects/jarvis-app
npm install
npm run sync                      # builds the plugin's TypeScript, then npx cap sync (both platforms)
```

`ios/` and `android/` are committed, so there's no need for `npx cap add`. After changing
`capacitor.config.ts`, the plugin or `shell/`, run `npm run sync` again. To bake in a default address (the
app's own setting still wins): `JARVIS_SERVER_URL=https://<mac>.<tailnet>.ts.net npm run sync`.

**iOS:** `npm run ios` opens Xcode. Xcode resolves the Swift packages the first time (Capacitor, and
LiveKit with its WebRTC framework, about 70 MB). To check that it compiles without signing:
`npm run build:ios-sim`.

**Android:** `npm run android` opens Android Studio, which downloads Gradle 8.11.1 and the dependencies from
Google, Maven Central and JitPack on the first sync. From a terminal:

```sh
cd android
./gradlew assembleDebug                         # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :jarvis-audio:testDebugUnitTest       # the plugin's Kotlin unit tests
```

(If `./gradlew` can't find Java: `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`.)

## Tests

| Command | What |
|---|---|
| `npm test` | vitest: the page hook (`web-hook/native.ts`) against a fake plugin. |
| `npm run typecheck` | TypeScript for the config, the shell page, the hook and the plugin API. |
| `npm run test:ios` | `swift test` for JarvisAudioCore: server addresses, token replies, reconnect timing, captions, the chime, the Live Activity's status line. `npm run test:ios-direct` does the same with plain `swiftc` + `xctest`. |
| `npm run test:android` | The same logic in Kotlin, with JUnit through Gradle, plus the notification page links and the "is a call holding the audio" check. `npm run test:android-direct` compiles it with Android Studio's bundled Kotlin compiler instead, without Gradle. |
| `npm run check:web-patch` | Applies `web-hook/jarvis-web.patch` to a copy of `../jarvis/web`, then typechecks it and runs its tests. |
| `npm run check:preferences-patch` | Applies `web-hook/jarvis-preferences.patch` to a copy of the jarvis repo, then typechecks the web app and runs its tests and the panel's Python tests. |
| `npm run check:mic-sync-patch` | Applies `web-hook/jarvis-mic-sync.patch` to a copy of `../jarvis/web`, checks its `bindNative` matches `web-hook/native.ts`, then typechecks it and runs its tests. |
| `npm run check:server-patch` | Applies `server-hook/jarvis-native-push.patch` to a copy of the jarvis Python package and tests, then runs them with the jarvis project's environment. |

## Install on the iPhone

1. Plug the iPhone into the Mac (or have both on the same Wi-Fi after the first cabled run), and unlock it.
2. `npm run ios`. In Xcode, select the **App** target → **Signing & Capabilities**, tick **Automatically
   manage signing**, and pick a **Team**: your paid developer team, or your Apple ID's free **Personal Team**
   (Xcode → Settings → Accounts → + to add the Apple ID). If Xcode says the bundle id `com.anil.jarvis` is
   taken, change it to something of your own, e.g. `com.anilmeena.jarvis`. The **Push Notifications**
   capability is listed there (from `App.entitlements`); with a paid team Xcode adds it to the App ID on its
   own. A Personal Team can't sign it: remove the capability there (the − on it) to build without
   notifications.
3. Pick the iPhone as the run destination at the top, and press Run (⌘R).
4. First time only, on the iPhone:
   - **Developer Mode:** Settings → Privacy & Security → Developer Mode → on. The iPhone restarts; confirm
     Turn On after it does. (The option only appears once Xcode has tried to run an app on it.)
   - **Trust the developer** (free team, or the first install from a new team): Settings → General → VPN &
     Device Management → your Apple ID under Developer App → Trust.
   Then press Run again.
5. Open JARVIS: enter `https://<mac-name>.<tailnet>.ts.net` (Tailscale on, on both), then the passcode on the
   page as usual, and allow the microphone, then notifications when iOS asks (once the session is up). Lock
   the phone and keep talking.

From the terminal instead of Xcode's Run button (the device id is from `xcrun devicectl list devices`, the team
id from Xcode → Settings → Accounts):

```sh
cd ~/Desktop/projects/jarvis-app/ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Debug -destination 'id=<device id>' \
  -derivedDataPath ../../.build/DeviceData -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> build
xcrun devicectl device install app --device <device id> ../../.build/DeviceData/Build/Products/Debug-iphoneos/App.app
```

With a **free Personal Team** the app stops opening after 7 days (the profile expires): plug in and press Run
again to renew it. A paid team's profile lasts a year. Settings → JARVIS changes the address; it applies the
next time the app opens (swipe it away first).

## Install on an Android phone

1. On the phone: Settings → About phone → tap **Build number** seven times, then Settings → System →
   Developer options → **USB debugging** on. Plug it in and allow the Mac when asked.
2. Either `npm run android` and press Run in Android Studio with the phone selected, or:
   ```sh
   cd android && ./gradlew assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
   (You can also copy the APK to the phone and open it, after allowing installs from that app.)
3. Open JARVIS, enter the Mac's Tailscale address, then the passcode, and allow the microphone, notifications
   and Nearby devices (for Bluetooth headsets). The notification shows while a session is on.

### Android notifications (Firebase)

JARVIS's alerts reach Android through Firebase Cloud Messaging. Setting it up takes one Firebase project, used by
both sides:

| Step | Where | What |
|---|---|---|
| 1 | [console.firebase.google.com](https://console.firebase.google.com) | **Add project** (Analytics isn't needed), then **Add app → Android** with package `com.anil.jarvis` (or yours, if you changed `applicationId`). |
| 2 | the app | Download **google-services.json** into `android/app/`, then rebuild and reinstall (`./gradlew assembleDebug`, `adb install -r …`). The file is git-ignored. |
| 3 | the Mac | Firebase console → Project settings → **Service accounts** → **Generate new private key**. Save it as `secrets/fcm_service_account.json` in the jarvis repo, `chmod 600` it, then `make services-restart`. No env var is needed: the project id is read from the file. |
| 4 | the phone | Start a session and allow notifications when asked. |

To check it end to end: `logs/web.log` on the Mac shows `app push token saved for android (fcm)`, and the next
finished background task or heartbeat alert shows on the phone with the app closed. Failures are in
`logs/tasks.log` as `FCM push to android failed: …`, and on the phone in `adb logcat -s JarvisAudio`. The Mac
keeps the tokens in `data/fcm_devices.json`, and drops one when FCM says it's no longer valid. The Mac side is
documented in the jarvis repo's `docs/mobile.md` (Android push on the Mac).

Some phones (Samsung, Xiaomi and others) kill background apps aggressively: if the session stops with the
screen off, set JARVIS's battery use to Unrestricted in its app info.

**Emulator / simulator:** the iOS simulator can use `http://localhost:8787` directly. On the Android
emulator, `http://10.0.2.2:8787` reaches the page, but `/api/token` then hands back a LiveKit URL the emulator
can't use; `adb reverse tcp:8787 tcp:8787 && adb reverse tcp:7880 tcp:7880` and `http://localhost:8787` work
better. Neither simulator has an earphone button to test.

## Status

| Piece | State |
|---|---|
| TypeScript (plugin API, shell page, hook) | typechecks; 13 vitest tests pass |
| Swift core | 21 XCTest tests pass (`swiftc`) |
| Kotlin core | **33 JUnit tests pass** through Gradle |
| Android app, Kotlin plugin, service and activity | **compile**: `./gradlew assembleDebug` builds `app-debug.apk` with no Kotlin warnings |
| Android on a phone | **not run yet**: the emulator can't start in the sandbox this was built in, and no phone was attached |
| FCM end to end | not tried: needs your Firebase project (`google-services.json` and the Mac's service account) |

Things to check on a phone:

- **Both:** a session survives the screen being locked for a few minutes, a phone call, and Wi-Fi being turned
  off and on.
- **iOS:** the AirPods gesture and the wired button arrive during a session.
- **Android:**
  - headset buttons reach the media session while it's in communication mode;
  - the call-style notification shows the timer, Mute/Unmute (with the chime) and Hang Up;
  - on Android 16, the status bar chip shows;
  - a call mutes the mic and turns the speaker off, and the page offers both back after it;
  - "Mic paused" clears after a call;
  - a tapped alert opens its task.
