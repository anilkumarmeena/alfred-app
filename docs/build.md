<div align="center">

<img src="assets/logo.svg" width="72" alt="">

# 🔨 Build & test

**Everything you need to build both apps, run every test suite, and see what's been verified so far.**

[🏠 Home](../README.md) · [🧱 Architecture](architecture.md) · [🍎 iOS](ios.md) · [🤖 Android](android.md) · **🔨 Build & test** · [📲 Install](install.md) · [🔗 JARVIS side](jarvis-side.md) · [🌐 Web hook](../web-hook/README.md) · [🔔 Push hook](../server-hook/README.md)

</div>

---

<details>
<summary><b>📑 On this page</b></summary>

- [Requirements](#-requirements)
- [Build](#-build)
- [iOS](#-ios)
- [Android](#-android)
- [Tests](#-tests)
- [Status](#-status)
- [Things to check on a phone](#-things-to-check-on-a-phone)

</details>

## 📋 Requirements

| | Tool | Version |
|:-:|---|---|
| 🟩 | **Node** | 20+ (Capacitor 7; Capacitor 8 would need Node 22) |
| 🍎 | **Xcode** | 16.3+, for the LiveKit Swift package |
| 🤖 | **Android Studio** | With JDK 21 (its bundled JBR is fine) |

## 🔄 Build

From this repo's root:

```sh
npm install
npm run sync      # builds the plugin's TypeScript, then npx cap sync (both platforms)
```

- **`ios/` and `android/` are committed**, so there's no need for `npx cap add`.
- After changing `capacitor.config.ts`, the plugin or `shell/`, **run `npm run sync` again**.
- To bake in a default address (the app's own setting still wins):

```sh
JARVIS_SERVER_URL=https://<mac>.<tailnet>.ts.net npm run sync
```

## 🍎 iOS

**`npm run ios`** opens Xcode. The first time, Xcode resolves the Swift packages: Capacitor, and LiveKit with its
WebRTC framework (about 70 MB).

To check that it compiles **without signing**:

```sh
npm run build:ios-sim
```

## 🤖 Android

**`npm run android`** opens Android Studio, which downloads **Gradle 8.11.1** and the dependencies from Google,
Maven Central and JitPack on the first sync. From a terminal:

```sh
cd android
./gradlew assembleDebug                         # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :jarvis-audio:testDebugUnitTest       # the plugin's Kotlin unit tests
```

> [!TIP]
> If `./gradlew` can't find Java:
> `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`

## 🧪 Tests

| | Command | What it runs |
|:-:|---|---|
| 🧪 | `npm test` | vitest: the page hook (`web-hook/native.ts`) against a fake plugin |
| 📐 | `npm run typecheck` | TypeScript for the config, shell page, hook and plugin API |
| 🍎 | `npm run test:ios` | `swift test` for JarvisAudioCore |
| 🤖 | `npm run test:android` | The same logic in Kotlin, with JUnit through Gradle |
| 🌐 | `npm run check:web-patch` | `jarvis-web.patch` on a copy of `../jarvis/web` |
| 🔧 | `npm run check:preferences-patch` | `jarvis-preferences.patch` on a copy of the jarvis repo |
| 🎤 | `npm run check:mic-sync-patch` | `jarvis-mic-sync.patch` on a copy of `../jarvis/web` |
| 🔔 | `npm run check:server-patch` | `jarvis-native-push.patch` on a copy of the jarvis package |

- **`test:ios`** covers server addresses, token replies, reconnect timing, captions, the chime and the Live
  Activity's status line. **`test:ios-direct`** does the same with plain `swiftc` + `xctest`.
- **`test:android`** also covers the notification page links and the "is a call holding the audio" check.
  **`test:android-direct`** compiles it with Android Studio's bundled Kotlin compiler instead, without Gradle.
- **`check:web-patch`** applies the patch, then typechecks the copy and runs its tests.
- **`check:preferences-patch`** typechecks the web app and runs its tests and the panel's Python tests.
- **`check:mic-sync-patch`** also checks its `bindNative` matches `web-hook/native.ts`, then typechecks and tests.
- **`check:server-patch`** copies the jarvis Python package and tests, and runs them with the jarvis project's
  environment.
- The `check:*` scripts never touch the jarvis repo itself. They look for it at `../jarvis`; set `JARVIS_REPO` to
  point elsewhere.

## 📊 Status

| Piece | State |
|---|---|
| TypeScript (plugin API, shell page, hook) | ✅ typechecks; **16 vitest tests** pass |
| Swift core | ✅ **35 XCTest tests** pass |
| Kotlin core | ✅ **33 JUnit tests** pass through Gradle |
| Android app, Kotlin plugin, service and activity | ✅ **compile** with no Kotlin warnings |
| Android on a phone | 🚧 **not run yet** |
| FCM end to end | 🚧 not tried |

- The Android build is `./gradlew assembleDebug`, producing `app-debug.apk`.
- Android hasn't run on a phone: the emulator can't start in the sandbox this was built in, and no phone was
  attached.
- FCM needs your Firebase project (`google-services.json` and the Mac's service account).

## 📱 Things to check on a phone

**Both**

- A session survives the screen being locked for a few minutes, a phone call, and Wi-Fi being turned off and on.

**iOS**

- The AirPods gesture and the wired button arrive during a session.

**Android**

- Headset buttons reach the media session while it's in communication mode.
- The call-style notification shows the timer, Mute/Unmute (with the chime) and Hang Up.
- On Android 16, the status bar chip shows.
- A call mutes the mic and turns the speaker off, and the page offers both back after it.
- "Mic paused" clears after a call.
- A tapped alert opens its task.

---

<div align="center">

[← 🤖 Android](android.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [📲 Install →](install.md)

</div>
