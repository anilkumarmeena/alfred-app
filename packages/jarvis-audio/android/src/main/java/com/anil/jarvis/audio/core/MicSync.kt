package com.anil.jarvis.audio.core

/**
 * Keeps the LiveKit mic track in step with what the page shows: the user's mute and an interruption (a call holding
 * audio focus). Room reports that contradict it within [settleMs] of a change are ignored as echoes of our own switch.
 */
class MicSync(val settleMs: Long = 2_000) {
    private var changedAt: Long? = null

    fun changed(nowMs: Long) { changedAt = nowMs }

    fun settled(nowMs: Long): Boolean = changedAt.let { it == null || nowMs - it >= settleMs }

    /** The server heard our mic at [nowMs]: true if the track should be off, so it must be switched off again. */
    fun heardWhileOff(nowMs: Long, muted: Boolean, interrupted: Boolean): Boolean =
        settled(nowMs) && !target(muted, interrupted)

    companion object {
        // AudioManager RINGTONE, IN_CALL, CALL_SCREENING, CALL_REDIRECT, COMMUNICATION_REDIRECT, as plain
        // numbers so this runs in JVM tests.
        private val CALL_MODES = setOf(1, 2, 4, 5, 6)

        fun target(muted: Boolean, interrupted: Boolean): Boolean = !muted && !interrupted

        /**
         * Whether a phone call holds the audio, from AudioManager.getMode(). Android doesn't always return focus after
         * a transient loss, so this lets the app end a stuck "Mic paused". MODE_IN_COMMUNICATION (JARVIS's own, and
         * VoIP apps') doesn't count.
         */
        fun callHoldsAudio(mode: Int): Boolean = mode in CALL_MODES
    }
}
