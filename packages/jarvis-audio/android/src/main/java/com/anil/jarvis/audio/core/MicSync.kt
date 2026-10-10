package com.anil.jarvis.audio.core

/**
 * Keeps the mic track and what the page shows in step. Two things decide whether the user is heard: their mute
 * (the screen, the headset button, the notification) and an interruption (a call holding audio focus). The page
 * shows those two ("Muted", "Mic paused"), so the LiveKit track has to follow them after every change, reconnect
 * and interruption, and when the room says the mic is doing something else, the track is switched again.
 */
class MicSync(val settleMs: Long = 2_000) {
    private var changedAt: Long? = null

    /** The mute or the interruption changed at [nowMs] (any monotonic clock). */
    fun changed(nowMs: Long) { changedAt = nowMs }

    /** Whether reports from the room at [nowMs] describe the mic as the app has it now. */
    fun settled(nowMs: Long): Boolean = changedAt.let { it == null || nowMs - it >= settleMs }

    /**
     * The server heard this device's mic at [nowMs], which only happens while the track is sending. True when it
     * shouldn't be (the user muted it, or a call has the audio focus), so it has to be switched off again.
     */
    fun heardWhileOff(nowMs: Long, muted: Boolean, interrupted: Boolean): Boolean =
        settled(nowMs) && !target(muted, interrupted)

    companion object {
        // AudioManager's modes while a phone call has the audio: RINGTONE, IN_CALL, CALL_SCREENING, CALL_REDIRECT
        // and COMMUNICATION_REDIRECT (the plain numbers, so this runs in JVM tests).
        private val CALL_MODES = setOf(1, 2, 4, 5, 6)

        /** Whether the mic track should be on: only while the user isn't muted and no call has the audio focus. */
        fun target(muted: Boolean, interrupted: Boolean): Boolean = !muted && !interrupted

        /**
         * Whether a phone call still holds the audio, from AudioManager.getMode(). Android doesn't promise the focus
         * back after every transient loss (another app can keep it), and one that never comes would leave the page
         * saying "Mic paused" for good: so when the user unmutes or the app comes on screen and no call is ringing
         * or going on, the interruption is over. JARVIS's own session is MODE_IN_COMMUNICATION, which doesn't count.
         */
        fun callHoldsAudio(mode: Int): Boolean = mode in CALL_MODES
    }
}
