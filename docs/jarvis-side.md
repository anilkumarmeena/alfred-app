<div align="center">

<img src="assets/logo.svg" width="72" alt="">

# 🔗 JARVIS side

**The changes the jarvis repo needs for the app, which one is required, and what happens until each is applied.**

[🏠 Home](../README.md) · [🧱 Architecture](architecture.md) · [🍎 iOS](ios.md) · [🤖 Android](android.md) · [🔨 Build & test](build.md) · [📲 Install](install.md) · **🔗 JARVIS side** · [🌐 Web hook](../web-hook/README.md) · [🔔 Push hook](../server-hook/README.md)

</div>

---

| | Change | Needed? | Then |
|:-:|---|:-:|---|
| 🌐 | [**1. Web page**](#-1-web-page) | **Required** | `make web-build` |
| 🎫 | [**2. Voice session server**](#-2-voice-session-server) | Nothing to do | — |
| 🔔 | [**3. Notifications**](#-3-notifications) | For alerts | Per platform |
| 🔧 | [**4. Settings → Preferences**](#-4-settings--preferences) | Optional | `make services-restart` |
| 🎤 | [**5. Mic state sync**](#-5-mic-state-sync) | Bug fix | `make web-build` |

## 🌐 1. Web page

Apply **`web-hook/jarvis-web.patch`** to the jarvis repo, as described in [🌐 Web hook](../web-hook/README.md), and
rebuild the page (`make web-build`).

> [!WARNING]
> Until then the app still works, but **as a plain web view**: the page opens its own LiveKit session, and **the mic
> stops in the background**.

## 🎫 2. Voice session server

**None.** The app uses the existing `/api/token`, the existing passcode and the existing Tailscale Serve setup
(`make tailscale-serve`). `logs/web.log` shows the phone as device `iphone` or `android`.

## 🔔 3. Notifications

App web views have **no Web Push**, so the jarvis server's pushes, which were Web Push only, never reached the app.
The app registers its own token and posts it to **`/api/push/native`**.

| | Platform | The jarvis side | Until it's there |
|:-:|---|---|---|
| 🍎 | **iPhone (APNs)** | `server-hook/jarvis-native-push.patch` + an APNs auth key | Token refused with **404** |
| 🤖 | **Android (FCM)** | Already in jarvis (`jarvis/notify/fcm.py`) + a Firebase service account | Token refused with **400** |

- **iPhone:** the auth key comes from the Apple Developer account; see [🔔 Push hook](../server-hook/README.md). The
  404 is logged in Xcode's console, and nothing else changes.
- **Android:** the FCM support landed in the jarvis repo in commit `fcc5f99`. See
  [📲 Install → Android notifications](install.md#-android-notifications-firebase). Against a jarvis without it, the
  400 shows in `adb logcat -s JarvisAudio`, and nothing else changes.

## 🔧 4. Settings → Preferences

**`web-hook/jarvis-preferences.patch`** puts do not disturb, the voice settings (with Voice Isolation) and the
background-work settings on **one Preferences page**. It also adds the small `hold_status` panel action it reads do
not disturb with.

- Details: [🌐 Web hook → Settings → Preferences](../web-hook/README.md#-settings--preferences).
- **Nothing in the app changes for it:** apply it on the Mac and `make services-restart`.

## 🎤 5. Mic state sync

**`web-hook/jarvis-mic-sync.patch`** makes the page:

- **re-read the plugin's state** whenever it comes back on screen (events sent while the web view was suspended can
  be lost),
- **show the plugin's mute** when a mute is refused,
- **ask for the mic back** when the core is tapped during "Mic paused".

Details: [🌐 Web hook → Mic state sync](../web-hook/README.md#-mic-state-sync). Apply it on the Mac and
`make web-build`.

---

<div align="center">

[← 📲 Install](install.md) &nbsp;·&nbsp; [🏠 Home](../README.md) &nbsp;·&nbsp; [🌐 Web hook →](../web-hook/README.md)

</div>
