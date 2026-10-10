package com.anil.jarvis.audio

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.anil.jarvis.audio.core.ServerAddress
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The page's handle on [VoiceSession], and the server address setting. Method and event names match
 * src/definitions.ts. Starting a session also registers for JARVIS's notifications ([PushNotifications]), and a
 * tapped notification opens its page here. Links to jarvis-app://retry and jarvis-app://setup (the bundled error
 * page) are handled here too, since that page has no Capacitor bridge on Android.
 */
@CapacitorPlugin(
    name = "JarvisAudio",
    permissions = [
        Permission(strings = [Manifest.permission.RECORD_AUDIO], alias = JarvisAudioPlugin.MICROPHONE),
        Permission(strings = [Manifest.permission.POST_NOTIFICATIONS], alias = JarvisAudioPlugin.NOTIFICATIONS),
        Permission(strings = [Manifest.permission.BLUETOOTH_CONNECT], alias = JarvisAudioPlugin.BLUETOOTH),
    ],
)
class JarvisAudioPlugin : Plugin() {
    companion object {
        const val MICROPHONE = "microphone"
        const val NOTIFICATIONS = "notifications"
        const val BLUETOOTH = "bluetooth"  // Android 12+: needed to route the call audio to a Bluetooth headset
        private const val SCHEME = "jarvis-app"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val forward = VoiceSession.Listener { name, data -> notifyListeners(name, data) }

    override fun load() {
        VoiceSession.addListener(forward)
        // After the bridge's first load, which runs once onCreate is done: a tap that launched the app wins.
        PushNotifications.open = { url -> bridge.webView.post { bridge.webView.loadUrl(url) } }
        PushNotifications.tapped(context, activity.intent)
    }

    override fun handleOnNewIntent(intent: Intent) {
        super.handleOnNewIntent(intent)
        PushNotifications.tapped(context, intent)
    }

    override fun handleOnResume() { VoiceSession.foreground = true }
    override fun handleOnPause() { VoiceSession.foreground = false }

    override fun handleOnDestroy() {
        VoiceSession.removeListener(forward)  // the session carries on; a new bridge picks it up with getStatus
        PushNotifications.open = null
        scope.cancel()
    }

    // --- The session ---

    @PluginMethod
    fun start(call: PluginCall) {
        if (call.getString("passcode").isNullOrEmpty()) return call.reject("Enter your passcode first.", "UNAUTHORIZED")
        // The mic, and the first time also notifications (the session's own, and JARVIS's alerts), as iOS asks
        // for notifications when the first session starts. A refusal of those doesn't stop the session.
        if (getPermissionState(MICROPHONE) != PermissionState.GRANTED || runtimeAliases().any { getPermissionState(it) == PermissionState.PROMPT }) {
            return requestPermissionForAliases(runtimeAliases(), call, "startAfterPermission")
        }
        begin(call)
    }

    @PermissionCallback
    private fun startAfterPermission(call: PluginCall) {
        if (getPermissionState(MICROPHONE) == PermissionState.GRANTED) begin(call)
        else call.reject("Microphone access is blocked. Allow it for JARVIS in Settings, then try again.", "NO_MICROPHONE")
    }

    private fun begin(call: PluginCall) {
        val server = call.getString("serverUrl")?.let { ServerAddress.parseOrNull(it) } ?: ServerSettings.current(context)
            ?: return call.reject("JARVIS's address isn't set.", "NO_SERVER")
        val passcode = call.getString("passcode")!!
        val device = call.getString("device")?.takeIf { it.isNotBlank() } ?: "android"
        val muted = call.getBoolean("muted", false) ?: false
        val speakerOff = call.getBoolean("speakerOff", false) ?: false
        scope.launch {
            try {
                call.resolve(VoiceSession.start(context, server, passcode, device, muted, speakerOff))
                PushNotifications.register(context, server, passcode, device)
            } catch (f: VoiceSession.Failure) {
                call.reject(f.message, f.code)
            } catch (e: Exception) {
                call.reject(e.message ?: e.toString(), "SERVER")
            }
        }
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        scope.launch { VoiceSession.stop(); call.resolve() }
    }

    @PluginMethod
    fun setMuted(call: PluginCall) {
        val m = call.getBoolean("muted") ?: return call.reject("Say muted: true or false.")
        reply(call, "muted") { VoiceSession.setMuted(m, "user") }
    }

    @PluginMethod
    fun toggleMute(call: PluginCall) {
        reply(call, "muted") { VoiceSession.setMuted(!VoiceSession.muted, "user") }
    }

    /** Resolves with `{key: change()}`, the new state, or rejects with the session's failure. */
    private fun reply(call: PluginCall, key: String, change: suspend () -> Boolean) {
        scope.launch {
            try { call.resolve(JSObject().put(key, change())) }
            catch (f: VoiceSession.Failure) { call.reject(f.message, f.code) }
        }
    }

    /** Speaker off: JARVIS replies in text only, with no speech made at all. */
    @PluginMethod
    fun setSpeaker(call: PluginCall) {
        val off = call.getBoolean("off") ?: return call.reject("Say off: true or false.")
        reply(call, "off") { VoiceSession.setSpeaker(off, "user") }
    }

    /** The answer to the offer after a phone call: `restore` puts the mic and speaker back as they were before it. */
    @PluginMethod
    fun restoreAfterCall(call: PluginCall) {
        val restore = call.getBoolean("restore", false) ?: false
        scope.launch { VoiceSession.restoreAfterCall(restore); call.resolve() }
    }

    @PluginMethod
    fun sendText(call: PluginCall) {
        val text = call.getString("text")?.takeIf { it.isNotBlank() } ?: return call.reject("Nothing to send.")
        scope.launch {
            try { VoiceSession.sendText(text); call.resolve() }
            catch (f: VoiceSession.Failure) { call.reject(f.message, f.code) }
        }
    }

    @PluginMethod
    fun getStatus(call: PluginCall) {
        scope.launch { call.resolve(VoiceSession.status()) }
    }

    // --- Mic Mode: iOS only ---

    // Android has no Mic Mode an app can read or offer (its voice-call input already uses the phone's own noise
    // suppression and echo cancellation), so the page draws no Mic pill: getStatus() has no micMode.
    @PluginMethod
    fun getMicMode(call: PluginCall) { call.unavailable("Mic Modes are iOS only.") }

    @PluginMethod
    fun showMicModes(call: PluginCall) { call.unavailable("Mic Modes are iOS only.") }

    // --- The server address ---

    @PluginMethod
    fun getServerUrl(call: PluginCall) {
        val saved = ServerSettings.saved(context)
        val url = saved ?: ServerSettings.fromBuild(context)
        call.resolve(JSObject().put("url", url?.origin ?: JSONObject.NULL).put("fromBuild", saved == null && url != null))
    }

    @PluginMethod
    fun setServerUrl(call: PluginCall) {
        val address = try { ServerAddress.parse(call.getString("url").orEmpty()) }
            catch (p: ServerAddress.Problem) { return call.reject(p.message, "INVALID_URL") }
        ServerSettings.save(context, address)
        call.resolve(JSObject().put("url", address.origin))
        reload()
    }

    @PluginMethod
    fun clearServerUrl(call: PluginCall) {
        ServerSettings.clear(context)
        call.resolve()
        reload()
    }

    /** Start the bridge again, so Capacitor picks up the new server.url (MainActivity applies it). */
    private fun reload() {
        activity.runOnUiThread { activity.recreate() }
    }

    override fun shouldOverrideLoad(url: Uri): Boolean? {
        if (url.scheme != SCHEME) return null
        when (url.host) {
            "setup" -> { ServerSettings.requestSetup(context); reload() }
            else -> reload()  // "retry": load the page again
        }
        return true
    }

    // --- Permissions ---

    @PluginMethod
    override fun checkPermissions(call: PluginCall) {
        call.resolve(permissions())
    }

    @PluginMethod
    override fun requestPermissions(call: PluginCall) {
        requestPermissionForAliases(runtimeAliases(), call, "permissionsAnswered")
    }

    @PermissionCallback
    private fun permissionsAnswered(call: PluginCall) {
        call.resolve(permissions())
    }

    /** The permissions this Android version asks for at runtime: the mic always, the others where they exist. */
    private fun runtimeAliases() = listOfNotNull(
        MICROPHONE,
        NOTIFICATIONS.takeIf { Build.VERSION.SDK_INT >= 33 },
        BLUETOOTH.takeIf { Build.VERSION.SDK_INT >= 31 },
    ).toTypedArray()

    private fun permissions() = JSObject()
        .put(MICROPHONE, getPermissionState(MICROPHONE).toString())
        .put(NOTIFICATIONS, if (Build.VERSION.SDK_INT >= 33) getPermissionState(NOTIFICATIONS).toString() else "granted")
}
