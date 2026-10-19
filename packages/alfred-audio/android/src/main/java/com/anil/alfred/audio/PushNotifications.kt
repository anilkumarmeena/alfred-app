package com.anil.alfred.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.anil.alfred.audio.core.PushRegistration
import com.anil.alfred.audio.core.ServerAddress
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.IOException

/**
 * Alfred's alerts via FCM, since Web Push doesn't work in a web view. The token goes to alfred.web on each session
 * start (that's when the passcode is known); a tap opens the alert's page on the saved server.
 *
 * Needs a google-services.json at build time; without one it logs and does nothing. Main thread only.
 */
object PushNotifications {
    private const val TAG = "AlfredAudio"
    private const val CHANNEL = "jarvis_alerts"
    private const val EXTRA_URL = "com.anil.alfred.audio.PUSH_URL"
    private const val EXTRA_TITLE = "com.anil.alfred.audio.PUSH_TITLE"
    private const val EXTRA_BODY = "com.anil.alfred.audio.PUSH_BODY"

    private data class Target(val server: ServerAddress, val passcode: String, val device: String)

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var app: Context

    /** Set by the plugin once the bridge is up; a tap before that is held until then. */
    var open: ((String) -> Unit)? = null
        set(value) {
            field = value
            val url = pending ?: return
            if (value != null) { pending = null; value(url) }
        }
    private var pending: String? = null

    private var target: Target? = null  // the latest session's server and passcode
    private var token: String? = null
    private var sent: Target? = null  // where the current token was last accepted
    private var sending = false

    fun register(context: Context, server: ServerAddress, passcode: String, device: String) {
        app = context.applicationContext
        target = Target(server, passcode, device)
        val messaging = try { FirebaseMessaging.getInstance() } catch (e: IllegalStateException) {
            Log.i(TAG, "notifications: the app was built without a Firebase project (google-services.json)")
            return
        }
        // Every time: the token can change, and Firebase answers quickly.
        messaging.token.addOnCompleteListener { t ->
            if (t.isSuccessful && t.result != null) tokenChanged(t.result) else Log.w(TAG, "notifications: no FCM token", t.exception)
        }
    }

    fun tokenChanged(t: String) {
        main.post {
            if (t != token) { token = t; sent = null }
            send()
        }
    }

    /** Skipped if this server already has it from this launch; failures retry on the next session start. */
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
                if (this@PushNotifications.target != target) send()  // a new session started meanwhile
            }
        }
    }

    // --- Showing them ---

    /**
     * Shows {title, body, url, tag, subtitle}; a newer push with the same tag replaces the older, as on Web Push and
     * APNs. Called on Firebase's thread, possibly with the app not running.
     */
    fun show(context: Context, data: Map<String, String>) {
        val ctx = context.applicationContext
        val title = data["title"]?.takeIf { it.isNotBlank() } ?: "Alfred"
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
            .setSmallIcon(R.drawable.alfred_audio_notify)
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
            Log.w(TAG, "notifications are turned off for Alfred")
        }
    }

    // --- Tapping them ---

    /** Opens the page of a tapped [show] notification, if [intent] carries one. */
    fun tapped(context: Context, intent: Intent?) {
        val url = intent?.getStringExtra(EXTRA_URL) ?: return
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)
        intent.removeExtra(EXTRA_URL)  // recreating the activity mustn't open it again
        if (ServerSettings.showingSetup(context)) return
        val page = ServerSettings.current(context)?.page(url, title, body) ?: return  // only ever the saved server
        open?.invoke(page) ?: run { pending = page }
    }
}
