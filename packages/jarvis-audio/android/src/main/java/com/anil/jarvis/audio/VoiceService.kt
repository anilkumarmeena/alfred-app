package com.anil.jarvis.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.KeyEvent

/**
 * Keeps JARVIS in the foreground while a session is wanted: a microphone-type foreground service, so Android
 * lets the mic run with the screen off or another app in front, and a notification that says what JARVIS is
 * doing, with Mute and End. Its media session takes headset button presses (wired hook, Bluetooth play/pause)
 * and turns them into mute toggles. The session itself is [VoiceSession]; this only keeps it alive.
 */
class VoiceService : Service() {
    companion object {
        private const val TAG = "JarvisAudio"
        private const val CHANNEL = "jarvis_session"
        private const val NOTIFICATION = 7880
        private const val ACTION_TOGGLE = "com.anil.jarvis.audio.TOGGLE_MUTE"
        private const val ACTION_END = "com.anil.jarvis.audio.END"
        private var running: VoiceService? = null

        fun start(ctx: Context) {
            try { ctx.startForegroundService(Intent(ctx, VoiceService::class.java)) }
            catch (e: Exception) { Log.w(TAG, "couldn't start the foreground service", e) }
        }

        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, VoiceService::class.java)) }

        fun update() { running?.refresh() }
    }

    private lateinit var media: MediaSession
    private var shown: Pair<String, Boolean>? = null  // the summary and mute state last put in the notification

    // Built once: each PendingIntent is a call to the system.
    private val open by lazy {
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        }
    }
    private val toggle by lazy { serviceIntent(ACTION_TOGGLE) }
    private val endSession by lazy { serviceIntent(ACTION_END) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Voice session", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while JARVIS is listening"
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
            ACTION_TOGGLE -> VoiceSession.earphonePress("user")
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
        val muted = VoiceSession.muted
        val now = VoiceSession.summary() to muted
        if (now == shown) return
        shown = now
        media.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP)
            .setState(if (muted) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
            .build())
        media.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, "JARVIS")
            .putString(MediaMetadata.METADATA_KEY_ARTIST, now.first)
            .build())
        if (VoiceSession.active) getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
    }

    private fun notification(): Notification {
        val muted = VoiceSession.muted
        fun action(icon: Int, title: String, intent: PendingIntent) =
            Notification.Action.Builder(Icon.createWithResource(this, icon), title, intent).build()
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.jarvis_audio_mic)
            .setContentTitle("JARVIS")
            .setContentText(VoiceSession.summary())
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(action(if (muted) R.drawable.jarvis_audio_mic else R.drawable.jarvis_audio_mic_off, if (muted) "Unmute" else "Mute", toggle))
            .addAction(action(R.drawable.jarvis_audio_end, "End", endSession))
            .setStyle(Notification.MediaStyle().setMediaSession(media.sessionToken).setShowActionsInCompactView(0, 1))
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
            .build()
    }

    private fun serviceIntent(action: String): PendingIntent =
        PendingIntent.getService(this, action.hashCode(), Intent(this, VoiceService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE)

    private fun keyEvent(intent: Intent): KeyEvent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
}
