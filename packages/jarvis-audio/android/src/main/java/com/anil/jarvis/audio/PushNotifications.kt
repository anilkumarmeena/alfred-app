package com.anil.jarvis.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.anil.jarvis.audio.core.PushRegistration
import com.anil.jarvis.audio.core.ServerAddress
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.IOException

/**
 * JARVIS's notifications in the app: heartbeat alerts and background tasks that finish, fail or have a question.
 * The page's Web Push doesn't work in an app's web view, so the app registers with Firebase Cloud Messaging itself
 * and hands the token to jarvis.web (/api/push/native) whenever a voice session starts, when it has the passcode.
 * The Mac sends data messages, which [JarvisMessagingService] gets even with the app closed and shows here; tapping
 * one opens its page (/?task=3) on the JARVIS server. The iOS side does the same with APNs.
 *
 * Needs the app built with a google-services.json (a Firebase project); without one Firebase isn't set up, and this
 * logs that once and does nothing. Everything here runs on the main thread.
 */
object PushNotifications {
    private const val TAG = "JarvisAudio"
    private const val CHANNEL = "jarvis_alerts"
    private const val EXTRA_URL = "com.anil.jarvis.audio.PUSH_URL"
    private const val EXTRA_TITLE = "com.anil.jarvis.audio.PUSH_TITLE"
    private const val EXTRA_BODY = "com.anil.jarvis.audio.PUSH_BODY"

    private data class Target(val server: ServerAddress, val passcode: String, val device: String)

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var app: Context

    /** Loads a page in the web view: set by the plugin once the bridge is up. A tap before that waits for it. */
    var open: ((String) -> Unit)? = null
        set(value) {
            field = value
            val url = pending ?: return
            if (value != null) { pending = null; value(url) }
        }
    private var pending: String? = null

    private var target: Target? = null  // where the token goes: the latest session's server and passcode
    private var token: String? = null
    private var sent: Target? = null  // the target the current token was last handed to
    private var sending = false

    /** Asks Firebase for the token, which goes to the server once it comes. */
    fun register(context: Context, server: ServerAddress, passcode: String, device: String) {
        app = context.applicationContext
        target = Target(server, passcode, device)
        val messaging = try { FirebaseMessaging.getInstance() } catch (e: IllegalStateException) {
            // No google-services.json in the build: Firebase never started.
            Log.i(TAG, "notifications: the app was built without a Firebase project (google-services.json)")
            return
        }
        // Every time: the token can change, and Firebase answers quickly with the current one.
        messaging.token.addOnCompleteListener { t ->
            if (t.isSuccessful && t.result != null) tokenChanged(t.result) else Log.w(TAG, "notifications: no FCM token", t.exception)
        }
    }

    /** A new token from Firebase ([JarvisMessagingService.onNewToken]), or the current one. */
    fun tokenChanged(t: String) {
        main.post {
            if (t != token) { token = t; sent = null }
            send()
        }
    }

    /** Hands the token over, unless this server already has it from this launch. A refusal or a network failure is
     * tried again when the next session starts. */
    private fun send() {
        val token = token ?: return
        val target = target ?: return
        if (sending || sent == target) return
        sending = true
        scope.launch {
            try {
                val (status, json) = Http.post(target.server.pushUrl,
                    PushRegistration.fields(target.passcode, target.device, token, app.packageName))
                PushRegistration.parse(status) { Http.field(json, it) }
                    .onSuccess { sent = target; Log.i(TAG, "notifications registered with ${target.server.host}") }
                    .onFailure { Log.w(TAG, "notification token not taken: ${it.message}") }
            } catch (e: IOException) {
                Log.w(TAG, "notification token: ${e.message}")
            } finally {
                sending = false
                if (this@PushNotifications.target != target) send()  // a new session, maybe with another server, started meanwhile
            }
        }
    }

    // --- Showing them ---

    /**
     * Shows a push from the Mac: {title, body, url, tag, subtitle}. A newer one with the same tag replaces the older
     * one, as on Web Push and APNs. Called on Firebase's thread, with the app maybe not on screen or not running.
     */
    fun show(context: Context, data: Map<String, String>) {
        val ctx = context.applicationContext
        val title = data["title"]?.takeIf { it.isNotBlank() } ?: "JARVIS"
        val body = data["body"].orEmpty()
        val url = data["url"]?.takeIf { it.isNotBlank() } ?: "/"
        val tag = data["tag"].orEmpty()
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Heartbeat alerts, and background tasks that finish, fail or have a question"
        })
        // Untagged pushes each get their own notification; tagged ones share one per tag.
        val id = if (tag.isEmpty()) (System.currentTimeMillis() and 0x7fffffff).toInt() else 1
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_URL, url); putExtra(EXTRA_TITLE, title); putExtra(EXTRA_BODY, body)
        }
        val tap = launch?.let {
            PendingIntent.getActivity(ctx, if (tag.isEmpty()) id else tag.hashCode(), it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.jarvis_audio_notify)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .apply { data["subtitle"]?.takeIf { it.isNotBlank() }?.let { setSubText(it) } }
            .build()
        try {
            nm.notify(tag.ifEmpty { null }, id, n)
        } catch (e: SecurityException) {
            Log.w(TAG, "notifications are turned off for JARVIS")
        }
    }

    // --- Tapping them ---

    /** The activity was started or brought back by a tap on one of [show]'s notifications: open its page. */
    fun tapped(context: Context, intent: Intent?) {
        val url = intent?.getStringExtra(EXTRA_URL) ?: return
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)
        intent.removeExtra(EXTRA_URL)  // once: recreating the activity mustn't open it again
        if (ServerSettings.showingSetup(context)) return
        val page = ServerSettings.current(context)?.page(url, title, body) ?: return  // only ever the saved server
        open?.invoke(page) ?: run { pending = page }
    }
}
