package com.anil.alfred.audio

import android.content.Context
import android.media.AudioManager
import android.os.Build
import com.anil.alfred.audio.core.MicSync

/**
 * Reports when a phone call starts or ends, from AudioManager's mode, which needs no READ_PHONE_STATE. Android 12+
 * reports mode changes; before that [check] runs on each audio focus change, which a call always brings. VoIP calls
 * share Alfred's communication mode so aren't seen (their focus loss still pauses the mic), unlike iOS's CallKit.
 * Main thread only.
 */
internal class CallWatch(context: Context, private val onChange: (Boolean) -> Unit) {
    private val ctx = context.applicationContext
    private val audio = ctx.getSystemService(AudioManager::class.java)
    private var listener: AudioManager.OnModeChangedListener? = null

    var onCall = false
        private set

    /** Also reports a call already on. */
    fun start() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && listener == null) {
            val l = AudioManager.OnModeChangedListener { check() }
            try { audio?.addOnModeChangedListener(ctx.mainExecutor, l); listener = l } catch (_: Exception) {}
        }
        check()
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) listener?.let { audio?.removeOnModeChangedListener(it) }
        listener = null
        onCall = false
    }

    fun check() {
        val on = MicSync.callHoldsAudio(audio?.mode ?: return)
        if (on == onCall) return
        onCall = on
        onChange(on)
    }
}
