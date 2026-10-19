<div align="center">

<img src="assets/logo.svg" width="72" alt="">

# 📲 Install

**Put Alfred on an iPhone or an Android phone, turn on Android alerts, or try it in a simulator.**

[🏠 Home](../README.md) · [🧱 Architecture](architecture.md) · [🍎 iOS](ios.md) · [🤖 Android](android.md) · [🔨 Build & test](build.md) · **📲 Install** · [🤝 Contributing](../CONTRIBUTING.md)

</div>

---

> [!IMPORTANT]
> Build first ([🔨 Build & test](build.md)), and have **Tailscale on, on both** the Alfred computer and the phone, with
> a current Alfred (`master`) served by `make tailscale-serve` ([how](https://github.com/anilkumarmeena/alfred/blob/master/docs/mobile.md#-get-it-on-your-phone)).

## 🍎 On the iPhone

**1. Connect** — plug the iPhone into the Mac and unlock it. After the first cabled run, both on the same Wi-Fi is
enough.

**2. Sign** — run `npm run ios`. In Xcode, select the **App** target → **Signing & Capabilities**, tick
**Automatically manage signing**, and pick a **Team**:

| Team | Push notifications | Profile lasts |
|---|---|---|
| **Paid developer team** | ✅ Xcode adds the capability to the App ID itself | A year |
| **Free Personal Team** | ❌ Can't sign it: remove the capability first | 7 days |

- Add an Apple ID in Xcode → Settings → Accounts → **+**.
- If Xcode says the bundle id `com.anil.jarvis` is taken, change it to your own, e.g. `com.yourname.alfred`.
- The **Push Notifications** capability is listed there (from `App.entitlements`). With a Personal Team, remove it
  (the **−** on it) to build without notifications.

**3. Run** — pick the iPhone as the run destination at the top, and press **Run (⌘R)**.

**4. First time only, on the iPhone:**

- **Developer Mode:** Settings → Privacy & Security → Developer Mode → on. The iPhone restarts; confirm **Turn On**
  after it does. The option only appears once Xcode has tried to run an app on it.
- **Trust the developer** (free team, or the first install from a new team): Settings → General → VPN & Device
  Management → your Apple ID under Developer App → **Trust**.

Then press Run again.

**5. Open Alfred** — enter `https://<computer-name>.<tailnet>.ts.net`, then the passcode on the page as usual. Allow the
microphone, then notifications when iOS asks (once the session is up). **Lock the phone and keep talking.**

> [!WARNING]
> With a **free Personal Team the app stops opening after 7 days**, when the profile expires. Plug in and press Run
> again to renew it.

- **Changing the address:** Settings → Alfred. It applies the next time the app opens (swipe it away first).

<details>
<summary><b>⌨️ Build and install from the terminal instead</b></summary>

<br>

The device id is from `xcrun devicectl list devices`; the team id from Xcode → Settings → Accounts. From this repo's
root:

```sh
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Debug -destination 'id=<device id>' \
  -derivedDataPath ../../.build/DeviceData -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> build
xcrun devicectl device install app --device <device id> ../../.build/DeviceData/Build/Products/Debug-iphoneos/App.app
```

</details>

## 🤖 On an Android phone

**1. Enable USB debugging** — Settings → About phone → tap **Build number** seven times, then Settings → System →
Developer options → **USB debugging** on. Plug it in and allow the computer when asked.

**2. Install** — either `npm run android` and press Run in Android Studio with the phone selected, or:

```sh
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

You can also copy the APK to the phone and open it, after allowing installs from that app.

**3. Open Alfred** — enter the Alfred computer's Tailscale address, then the passcode. Allow the **microphone**, **notifications**
and **Nearby devices** (for Bluetooth headsets). The notification shows while a session is on.

> [!TIP]
> Some phones (Samsung, Xiaomi and others) **kill background apps aggressively**. If the session stops with the
> screen off, set Alfred's battery use to **Unrestricted** in its app info.

## 🔔 Android notifications (Firebase)

Alfred's alerts reach Android through **Firebase Cloud Messaging**. It takes **one Firebase project, used by both
sides**:

| Step | Where | What |
|:-:|---|---|
| 1 | [Firebase console](https://console.firebase.google.com) | **Add project**, then **Add app → Android** |
| 2 | The app | Put **google-services.json** in `android/app/`, rebuild, reinstall |
| 3 | The Alfred computer | Save a **service account key** in the alfred repo, restart services |
| 4 | The phone | Start a session and allow notifications |

- **Step 1:** Analytics isn't needed. Use package `com.anil.jarvis`, or yours if you changed `applicationId`.
- **Step 2:** rebuild and reinstall with `./gradlew assembleDebug` and `adb install -r …`. The file is git-ignored.
- **Step 3:** Firebase console → Project settings → **Service accounts** → **Generate new private key**. Save it as
  `secrets/fcm_service_account.json` in the alfred repo, `chmod 600` it, then `make services-restart`. **No env var
  is needed**: the project id is read from the file.

**Check it end to end**

| | Where | What to look for |
|:-:|---|---|
| ✅ | `logs/web.log` on the computer | `app push token saved for android (fcm)` |
| 📱 | The phone, app closed | The next finished background task or heartbeat alert |
| ❌ | `logs/tasks.log` | `FCM push to android failed: …` |
| 🔍 | `adb logcat -s AlfredAudio` | Failures on the phone |

- The computer keeps the tokens in `data/fcm_devices.json`, and drops one when FCM says it's no longer valid.
- The computer's side is in the alfred docs: [Android push: on the computer](https://github.com/anilkumarmeena/alfred/blob/master/docs/mobile.md#android-push-on-the-computer).

## 💻 Emulator and simulator

| Simulator | Address | Notes |
|---|---|---|
| **iOS simulator** | `http://localhost:8787` | Works directly |
| **Android emulator** | `http://localhost:8787` | After the two `adb reverse` lines below |

```sh
adb reverse tcp:8787 tcp:8787 && adb reverse tcp:7880 tcp:7880
```

- On the Android emulator `http://10.0.2.2:8787` reaches the page, but `/api/token` then hands back a LiveKit URL
  the emulator can't use. The `adb reverse` route works better.
- **Neither simulator has an earphone button** to test.

---

<div align="center">

[← 🔨 Build & test](build.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [🤝 Contributing →](../CONTRIBUTING.md)

</div>
