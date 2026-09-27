# JARVIS for iPhone and Android

The phone app for JARVIS, Anil's voice assistant, built with Capacitor. It shows the live JARVIS web page from
the Mac, so changes to the page in the jarvis repo show up without rebuilding the app. The voice session runs
in a native plugin, JarvisAudio, and not in the web view, so:

- the mic keeps listening with the screen locked or another app in front (a mobile browser or plain web view
  stops it),
- JARVIS's voice keeps playing in the background,
- the earphone button mutes and unmutes: the AirPods stem press on iOS 17+, the wired EarPods button, a
  Bluetooth headset's play/pause, and the lock-screen or notification controls,
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
- Earphone button (`RemoteControls.swift`): on AirPods, iOS 17's mute gesture mutes the app's input itself and
  reports it with `AVAudioApplication.inputMuteStateChangeNotification`. The plugin follows it, and clears
  `AVAudioApplication.setInputMuted` when unmuting from the screen; it never sets it, since iOS answers that
  with its own tone and a notification that undid the mute. Wired and other headsets send
  `MPRemoteCommandCenter` play, pause and toggle commands, which toggle the mute and play the page's
  falling or rising chime. The lock screen's Now Playing card shows Listening, Muted, Speaking and so on.
- Interruptions: a call or Siri pauses the mic ("Mic paused"), and when it ends the session is reactivated.
  Route changes (AirPods in or out) go to the page as `route` events. A media services reset rejoins.
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

- `VoiceService` is a foreground service of type `microphone`, with an ongoing notification (Listening,
  Muted, Reconnecting…, with Mute and End). It runs for as long as the session is wanted, so the mic works
  with the screen off. Swiping the app away ends the session.
- LiveKit's `AudioSwitchHandler` sets communication mode, takes audio focus and routes to a Bluetooth
  headset, wired headset or the speaker, in that order. A transient loss of focus (a phone call) pauses the
  mic until it comes back.
- The service's `MediaSession` takes headset presses (the wired hook, Bluetooth play/pause) and the lock screen
  controls, and toggles the mute with the chime.
- Reconnects work as on iOS, with `ConnectivityManager` for network changes.
- Long-press the app icon → Change server.

### Layout

| Path | What |
|---|---|
| `capacitor.config.ts` | App id `com.anil.jarvis`, `webDir: shell`, optional build-time `server.url` from `JARVIS_SERVER_URL`, `errorPath`. |
| `shell/` | The bundled pages: first-run address prompt and the can't-reach-the-Mac page. |
| `packages/jarvis-audio/` | The plugin: `src/definitions.ts` (the TypeScript API), `ios/Sources/JarvisAudioPlugin` (Swift), `ios/JarvisAudioCore` (plain-Swift logic and its tests), `android/src/main/java/com/anil/jarvis/audio` (Kotlin; `core/` is the plain-Kotlin logic, tested in `android/src/test`). |
| `ios/`, `android/` | The native projects from `npx cap add`, with the changes below. |
| `web-hook/` | The page's side: `native.ts` and `jarvis-web.patch`, see [web-hook/README.md](web-hook/README.md). |
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
`FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`, `BLUETOOTH_CONNECT`, `ACCESS_NETWORK_STATE` and the
service.

## Changes needed on the JARVIS side

1. **Web (required):** apply `web-hook/jarvis-web.patch` to the jarvis repo, as described in
   [web-hook/README.md](web-hook/README.md), and rebuild the page (`make web-build`). Until then the app
   still works, but as a plain web view: the page opens its own LiveKit session, and the mic stops in the
   background.
2. **Server, for the voice session: none.** The app uses the existing `/api/token`, the existing passcode and
   the existing Tailscale Serve setup (`make tailscale-serve`). `logs/web.log` will show the phone as device
   `iphone` or `android`.
3. **Server, for notifications (iPhone):** app web views have no Web Push, so the jarvis server's pushes,
   which were Web Push only, never reached the app. The app now registers with APNs itself and posts its token
   to `/api/push/native`; the jarvis side of that is `server-hook/jarvis-native-push.patch`, plus an APNs auth
   key from the Apple Developer account. See [server-hook/README.md](server-hook/README.md). Until it's
   applied the app's token is refused with a 404 (logged in Xcode's console) and nothing else changes. Android
   still has no push: that needs FCM (a Firebase project and `google-services.json`) on both sides.

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
| `npm run test:ios` | `swift test` for JarvisAudioCore: server addresses, token replies, reconnect timing, earphone debouncing, captions, the chime. `npm run test:ios-direct` does the same with plain `swiftc` + `xctest`. |
| `npm run test:android` | The same logic in Kotlin, with JUnit through Gradle. `npm run test:android-direct` compiles it with Android Studio's bundled Kotlin compiler instead, without Gradle. |
| `npm run check:web-patch` | Applies `web-hook/jarvis-web.patch` to a copy of `../jarvis/web`, then typechecks it and runs its tests. |
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

Some phones (Samsung, Xiaomi and others) kill background apps aggressively: if the session stops with the
screen off, set JARVIS's battery use to Unrestricted in its app info.

**Emulator / simulator:** the iOS simulator can use `http://localhost:8787` directly. On the Android
emulator, `http://10.0.2.2:8787` reaches the page, but `/api/token` then hands back a LiveKit URL the emulator
can't use; `adb reverse tcp:8787 tcp:8787 && adb reverse tcp:7880 tcp:7880` and `http://localhost:8787` work
better. Neither simulator has an earphone button to test.

## Status

Written and checked here: the TypeScript (plugin API, shell page, hook) typechecks; 10 vitest tests pass;
the Swift core's 21 XCTest tests and the Kotlin core's 19 JUnit tests pass (built with `swiftc` and Android
Studio's Kotlin compiler); `jarvis-web.patch` applies to the current `web/`, which then typechecks and passes
its own 35 tests.

Not verified yet: the Swift plugin and the Kotlin plugin, service and activity haven't been compiled, because
the sandbox they were written in couldn't download LiveKit's and Capacitor's binaries (GitHub release assets)
or reach Maven, Google or Gradle's servers. Nothing has run on a phone. Expect a round of small compile fixes on
the first `npm run build:ios-sim` and `./gradlew assembleDebug`. Things to check on a phone: that the AirPods
gesture and wired button arrive during a session on iOS; that headset buttons reach the media session on
Android while it's in communication mode; and that a session survives the screen being locked for a few
minutes, a phone call, and Wi-Fi being turned off and on.
