package com.anil.jarvis.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.view.KeyEvent
import com.anil.jarvis.audio.core.SessionSummary

/**
 * Keeps JARVIS in the foreground while a session is wanted: a microphone-type foreground service, so Android lets
 * the mic run with the screen off or another app in front. Its notification is Android's counterpart of the iOS Live
 * Activity: **JARVIS**, what it's doing ([SessionSummary]), the session's running time, and Mute/Unmute and Hang Up.
 * On Android 12+ it's a call-style notification (JARVIS is a call the user left running), which the lock screen
 * and the status bar show as an ongoing call, and on Android 16 it asks to be promoted to a Live Update. Tapping
 * elsewhere opens the app. Its media session takes headset button presses (wired hook, Bluetooth play/pause) and
 * turns them into mute toggles; there's no media card (no MediaStyle), as there's no Now Playing on iOS. The session
 * itself is [VoiceSession]; this only keeps it alive and shows it.
 */
class VoiceService : Service() {
    companion object {
        private const val TAG = "JarvisAudio"
        private const val CHANNEL = "jarvis_session"
        private const val NOTIFICATION = 7880
        private const val ACTION_MUTE = "com.anil.jarvis.audio.MUTE"
        private const val ACTION_UNMUTE = "com.anil.jarvis.audio.UNMUTE"
        private const val ACTION_END = "com.anil.jarvis.audio.END"
        // Notification.EXTRA_REQUEST_PROMOTED_ONGOING (Android 16), by name so the plugin builds against SDK 35
        private const val EXTRA_PROMOTED_ONGOING = "android.requestPromotedOngoing"
        private var running: VoiceService? = null

        fun start(ctx: Context) {
            try { ctx.startForegroundService(Intent(ctx, VoiceService::class.java)) }
            catch (e: Exception) { Log.w(TAG, "couldn't start the foreground service", e) }
        }

        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, VoiceService::class.java)) }

        fun update() { running?.refresh() }
    }

    private lateinit var media: MediaSession
    private var shown: Pair<SessionSummary?, Long?>? = null  // what the notification last showed

    // Built once: each PendingIntent is a call to the system.
    private val open by lazy {
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        }
    }
    private val mute by lazy { serviceIntent(ACTION_MUTE) }
    private val unmute by lazy { serviceIntent(ACTION_UNMUTE) }
    private val hangUp by lazy { serviceIntent(ACTION_END) }
    private val jarvis by lazy {
        Person.Builder().setName("JARVIS").setImportant(true).setIcon(Icon.createWithResource(this, applicationInfo.icon)).build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Voice session", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while JARVIS is listening, with Mute and Hang Up"
                setShowBadge(false)
            })
        media = MediaSession(this, "JARVIS").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(intent: Intent): Boolean {
                    val key = keyEvent(intent) ?: return super.onMediaButtonEvent(intent)
                    return when (key.keyCode) {
                        KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                        KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                            if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) VoiceSession.earphonePress()
                            true
                        }
                        else -> super.onMediaButtonEvent(intent)
                    }
                }
                override fun onPlay() = VoiceSession.earphonePress()
                override fun onPause() = VoiceSession.earphonePress()
                override fun onStop() = VoiceSession.stop()
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()  // first, every time: Android stops a foreground-started service that doesn't
        when (intent?.action) {
            ACTION_MUTE -> VoiceSession.setMutedOffPage(true)
            ACTION_UNMUTE -> VoiceSession.setMutedOffPage(false)
            ACTION_END -> VoiceSession.stop()
        }
        if (VoiceSession.active) refresh() else stopSelf()
        return START_NOT_STICKY  // after the process dies there's no session to come back to
    }

    override fun onDestroy() {
        running = null
        media.isActive = false
        media.release()
        super.onDestroy()
    }

    // The user swiped JARVIS away from recents: end the session rather than listen with no app.
    override fun onTaskRemoved(rootIntent: Intent?) {
        VoiceSession.stop()
        super.onTaskRemoved(rootIntent)
    }

    private fun goForeground() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION, notification())
            }
        } catch (e: Exception) {
            // Android 14+ refuses a microphone service without the mic permission, or from the background.
            Log.w(TAG, "startForeground", e)
        }
    }

    fun refresh() {
        val now = VoiceSession.summary to VoiceSession.startedAt
        if (now == shown) return
        shown = now
        // Playing while the mic is live, so headset presses come here; the state is never shown as a media card.
        media.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP)
            .setState(if (VoiceSession.muted) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
            .build())
        if (!VoiceSession.active) return
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
        } catch (e: Exception) {
            Log.w(TAG, "notification update", e)
        }
    }

    private fun notification(): Notification {
        val summary = VoiceSession.summary
        val muted = VoiceSession.muted
        val startedAt = VoiceSession.startedAt
        val muteAction = action(if (muted) R.drawable.jarvis_audio_mic else R.drawable.jarvis_audio_mic_off,
            if (muted) "Unmute" else "Mute", if (muted) unmute else mute)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(if (muted) R.drawable.jarvis_audio_mic_off else R.drawable.jarvis_audio_mic)
            .setContentTitle("JARVIS")
            .setContentText(summary?.status ?: "Connecting…")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)  // nothing private in it: shown in full on the lock screen
            .apply {
                // The running time, from when the room was first joined, as the Live Activity shows it.
                if (startedAt != null) setWhen(startedAt).setShowWhen(true).setUsesChronometer(true) else setShowWhen(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Hang Up is the call style's own red button; Mute goes beside it.
                    setStyle(Notification.CallStyle.forOngoingCall(jarvis, hangUp))
                    addAction(muteAction)
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                } else {
                    addAction(muteAction)
                    addAction(action(R.drawable.jarvis_audio_end, "Hang Up", hangUp))
                }
                // Android 16: a Live Update, at the top of the lock screen and as a chip in the status bar. Ignored
                // before 16, and when the user turns Live Updates off for JARVIS.
                addExtras(Bundle().apply { putBoolean(EXTRA_PROMOTED_ONGOING, true) })
            }
            .build()
    }

    private fun action(icon: Int, title: String, intent: PendingIntent) =
        Notification.Action.Builder(Icon.createWithResource(this, icon), title, intent).build()

    private fun serviceIntent(action: String): PendingIntent =
        PendingIntent.getService(this, action.hashCode(), Intent(this, VoiceService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE)

    private fun keyEvent(intent: Intent): KeyEvent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
}
