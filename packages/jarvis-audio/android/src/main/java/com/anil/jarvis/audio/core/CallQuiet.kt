package com.anil.jarvis.audio.core

/**
 * A phone call turns JARVIS's mic and speaker off, so nothing of the call is heard by JARVIS and JARVIS says nothing
 * over it. When the call ends, the user is offered the mic and the speaker back as they were before it, if that's any
 * different; VoiceSession asks the page, which shows the offer. The same rules as the iOS side's CallQuiet.swift.
 */
class CallQuiet {
    data class State(val muted: Boolean, val speakerOff: Boolean)

    private var before: State? = null  // as it was when the call came in, until it ends

    /** What to offer to put back, from the end of the call until the user answers or changes either themselves. */
    var offer: State? = null
        private set

    /** A call is ringing or on, as the session is [now]. True the first time, when the mic and speaker go off. */
    fun began(now: State): Boolean {
        offer = null
        if (before != null) return false
        before = now
        return true
    }

    /** The call ended, leaving the session [now]: what to offer to put back, or null if it's as it was before. */
    fun ended(now: State): State? {
        val was = before ?: return null
        before = null
        offer = if (was == now) null else was
        return offer
    }

    /** The user answered the offer, or set the mic or speaker themselves: the offer is closed. Returns it, if open. */
    fun settle(): State? = offer.also { offer = null }
}
