package com.anil.alfred.audio.core

/**
 * A phone call turns the mic and speaker off; when it ends, the user is offered the previous state back if it
 * differs (the page shows the offer). Same rules as iOS CallQuiet.swift.
 */
class CallQuiet {
    data class State(val muted: Boolean, val speakerOff: Boolean)

    private var before: State? = null  // state when the call began

    /** Open from the call's end until the user answers or changes the mic or speaker themselves. */
    var offer: State? = null
        private set

    /** A call is ringing or on. True only the first time, when the mic and speaker should go off. */
    fun began(now: State): Boolean {
        offer = null
        if (before != null) return false
        before = now
        return true
    }

    /** The call ended: the state to offer back, or null if nothing changed. */
    fun ended(now: State): State? {
        val was = before ?: return null
        before = null
        offer = if (was == now) null else was
        return offer
    }

    /** Closes the offer and returns it, if open. */
    fun settle(): State? = offer.also { offer = null }
}
