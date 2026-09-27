# Native push: the JARVIS side

The app registers with Apple's push service (APNs) itself, because its web view has no Web Push. When a voice
session starts it posts its device token to `/api/push/native` on the Mac. `jarvis-native-push.patch` adds that
endpoint to the jarvis repo, and makes `send_push()`, which the task runner and the heartbeat already call for
tasks that finish, fail or have a question and for heartbeat alerts, send to the app through APNs as well as to
the Web Push subscriptions.

| File | Change |
|---|---|
| `jarvis/apns.py` (new) | The app devices (`data/push_devices.json`, mode 600, one per token), the ES256 provider token signed with the APNs auth key (reused for 50 minutes), and sending over HTTP/2 to `api.sandbox.push.apple.com` (builds Xcode installs) or `api.push.apple.com` (TestFlight, App Store). A 410, `BadDeviceToken`, `Unregistered` or `DeviceTokenNotForTopic` drops the device. Tokens never reach the log. |
| `jarvis/config.py` | `APNS_KEY_FILE` (`secrets/apns_key.p8`), `JARVIS_APNS_KEY_ID`, `JARVIS_APNS_TEAM_ID`, `PUSH_DEVICES_FILE`. |
| `jarvis/push.py` | `send_push()` sends Web Push and APNs together; one failing doesn't stop the other. |
| `jarvis/web.py` | `POST /api/push/native` with `{"passcode", "device", "token", "environment", "topic"}` → `{"ok": true, "sending": bool}`. 401 for a wrong passcode (and it counts towards the lockout), 400 for a malformed token, 409 while `JARVIS_PUSH` is off. The token is kept even before APNs is set up, with `sending: false` and a line in `logs/web.log` saying what's missing. |
| `tests/test_apns.py` (new), `tests/test_push.py` | 19 new tests; the Web Push tests keep their app devices in a temporary folder. |
| `web/src/state/push.ts` | In the app, the notifications message now says the app sets them up itself. |

The APNs payload is `{"aps": {"alert": {"title", "body"}, "sound": "default", "thread-id": tag}, "url", "tag"}`,
with `apns-collapse-id` set to the tag, so a newer push about the same task replaces the older one, as on Web Push.
The app opens `url` (such as `/?task=3#title=…&body=…`) on the saved server when the notification is tapped.

## Setting it up

1. **APNs auth key** (once, at developer.apple.com → Certificates, IDs & Profiles → Keys → +): name it
   JARVIS, tick **Apple Push Notifications service (APNs)**, Configure → environment **Sandbox & Production**,
   then Continue, Register, and **Download** (you get one chance). Note the **Key ID** on that page, and the
   **Team ID** under Membership details.
2. Put the key in place and tell JARVIS about it:
   ```sh
   cd ~/Desktop/projects/jarvis
   mv ~/Downloads/AuthKey_*.p8 secrets/apns_key.p8 && chmod 600 secrets/apns_key.p8
   ```
   and add to `.env` (`JARVIS_PUSH=on` should already be there, since the Home Screen web app gets pushes):
   ```
   JARVIS_APNS_KEY_ID=<Key ID>
   JARVIS_APNS_TEAM_ID=<Team ID>
   ```
3. Apply the patch, add HTTP/2 support, test, rebuild and restart:
   ```sh
   cd ~/Desktop/projects/jarvis
   git apply ../jarvis-app/server-hook/jarvis-native-push.patch
   uv add 'httpx[http2]'      # APNs only speaks HTTP/2; this adds h2 to pyproject.toml and uv.lock
   make test
   make services-restart      # rebuilds the page and restarts the web app and the task runner
   ```
   `sh ../jarvis-app/scripts/check-server-patch.sh` does a dry run first, on a copy.

To check it end to end: open the app, start a session and allow notifications when iOS asks. `logs/web.log`
shows `app push token saved for iphone (development)`. Then any finished background task, or a heartbeat alert,
shows up on the phone with the app closed. Failures are in `logs/tasks.log` as `APNs push to iphone … failed`.
