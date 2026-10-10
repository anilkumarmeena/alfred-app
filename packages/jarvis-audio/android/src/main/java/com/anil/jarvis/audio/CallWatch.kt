package com.anil.jarvis.audio

import android.content.Context
import android.media.AudioManager
import android.os.Build
import com.anil.jarvis.audio.core.MicSync

/**
 * Phone calls on the phone, for [VoiceSession]: [onChange] says whether a call is ringing, dialling or on, each time
 * that changes. It reads AudioManager's mode ([MicSync.callHoldsAudio]), which needs no permission (the phone state
 * would need READ_PHONE_STATE). Android 12+ reports every mode change; before that [check] runs on each audio focus
 * change, which a call always brings. Other apps' internet calls (WhatsApp, Meet…) use the same communication mode as
 * JARVIS itself, so they aren't seen as calls; their audio focus still pauses the mic ("Mic paused"). The iOS side's
 * CallWatch.swift sees those too, through CallKit. Runs on the main thread, for one session.
 */
internal class CallWatch(context: Context, private val onChange: (Boolean) -> Unit) {
    private val ctx = context.applicationContext
    private val audio = ctx.getSystemService(AudioManager::class.java)
    private var listener: AudioManager.OnModeChangedListener? = null

    var onCall = false
        private set

    /** Starts watching, and reports a call already on. */
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
