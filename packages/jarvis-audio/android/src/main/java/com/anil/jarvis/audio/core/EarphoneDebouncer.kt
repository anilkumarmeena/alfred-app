package com.anil.jarvis.audio.core

/**
 * One headset press can reach the media session more than once (as a key down and a play/pause callback, or
 * repeated by a Bluetooth stack). Only the first within [windowMs] counts.
 */
class EarphoneDebouncer(val windowMs: Long = 400) {
    private var last: Long? = null

    /** Whether a press at [nowMs] (any monotonic clock) is a new one. */
    fun accept(nowMs: Long): Boolean {
        val l = last
        if (l != null && nowMs - l in 0 until windowMs) return false
        last = nowMs
        return true
    }

    fun reset() { last = null }
}
