<div align="center">

<img src="docs/assets/logo.svg" width="72" alt="">

# 🤝 Contributing

**Thanks for helping! This page gets you from a fresh clone to a pull request that's easy to merge.**

[🏠 Home](README.md) · [🧱 Architecture](docs/architecture.md) · [🍎 iOS](docs/ios.md) · [🤖 Android](docs/android.md) · [🔨 Build & test](docs/build.md) · [📲 Install](docs/install.md) · **🤝 Contributing**

</div>

---

> [!IMPORTANT]
> You need **Node 20+**, **Xcode 16.3+** on a Mac for iOS, and **Android Studio** with JDK 21 for Android. To try the
> app for real you also need a running **[JARVIS](https://github.com/anilkumarmeena/jarvis)** (current `master`) and
> Tailscale. Details are in **[🔨 Build & test](docs/build.md#-requirements)**.

## 🚀 Your first pull request

**1. Set up** — install, then build the plugin and sync both native projects:

```sh
npm install
npm run sync
```

**2. Find your way around** — how the page, the plugin and the server fit together is in
**[🧱 Architecture](docs/architecture.md)**; each platform's details are in **[🍎 iOS](docs/ios.md)** and
**[🤖 Android](docs/android.md)**.

**3. Make one change, with a test** — follow the [code style](#-code-style) below. Logic belongs in the plain cores,
where it can be tested without a phone.

**4. Run the checks and open the PR** — the [checks](#-checks) must pass; then describe it as in
[pull requests](#-pull-requests).

## ✅ Checks

| | Command | Must |
|:-:|---|---|
| 📐 | `npm run typecheck` | Pass: config, shell page and plugin API |
| 🍎 | `npm run test:ios-direct` | Pass: the 35 Swift core tests (needs Xcode) |
| 🤖 | `npm run test:android-direct` | Pass: the 33 Kotlin core tests (needs Android Studio) |
| 🏗️ | `npm run build:ios-sim` | Build, if you touched iOS code (unsigned, no device needed) |
| 🏗️ | `npm run build:android` | Build, if you touched Android code |

- `npm run test:ios` and `npm run test:android` run the same tests through SwiftPM and Gradle; use whichever works on
  your machine.
- `test:android-direct` needs JUnit and Hamcrest in `~/.gradle`'s cache (any earlier Android build puts them there),
  and looks for Android Studio in `/Applications` unless `ANDROID_STUDIO` is set.
- Some things only show on a real phone (locked screen, calls, headset buttons): say in the PR what you ran it on.

## 🎨 Code style

- **Comments are short and explain why**, not what: the reason, the constraint or the trap. No history ("used to",
  "now") in comments; that belongs in the commit message.
- **iOS and Android stay in parity.** A behaviour change lands in both `JarvisAudioCore` (Swift) and `core/`
  (Kotlin), with tests on both.
- **The plugin API is a contract** with the page: change `packages/jarvis-audio/src/definitions.ts` together with
  both native plugins.
- **No personal data** in code, tests or docs: use placeholders like `https://your-computer.your-tailnet.ts.net`.
- **Say "the computer", not "the Mac"**, unless it's really Mac-only (Xcode, iOS builds): JARVIS also runs on Linux
  and Windows (WSL2).

> [!NOTE]
> The bundle id **`com.anil.jarvis`** is the project's own. For device builds, change it to yours (e.g.
> `com.yourname.jarvis`) in Xcode's signing settings (the App and widget targets) and `applicationId` in
> `android/app/build.gradle`; don't commit that change.

## 📬 Pull requests

| | What | How |
|:-:|---|---|
| 🎯 | **One change** | With a title that says what it does |
| 📝 | **A clear description** | What changed and why, how you tested it, on which phones |
| 📚 | **Docs updated** | The pages that describe the behaviour you changed |
| 🧹 | **Focused commits** | Rebased on `master` before asking for review |

> [!TIP]
> **Changes to the web page or the server belong in the [jarvis repo](https://github.com/anilkumarmeena/jarvis)**:
> the page's side of the plugin is `web/src/lib/native.ts` there. A plugin API change needs a pull request in both.

## 🐛 Reporting bugs

Open an issue with **what you did**, **what you expected** and **what happened**, the phone and OS version, and the
relevant log lines (Xcode's console or `adb logcat -s JarvisAudio`, with any personal details removed).

---

<div align="center">

By contributing, you agree that your contributions are licensed under the **[MIT License](LICENSE)**.

[← 📲 Install](docs/install.md) &nbsp;·&nbsp; [🏠 Home](README.md)

</div>
