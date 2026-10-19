package com.anil.alfred.audio.core

/**
 * One headset press can arrive more than once (key down plus play/pause callback, or Bluetooth repeats); only the
 * first within [windowMs] counts.
 */
class EarphoneDebouncer(val windowMs: Long = 400) {
    private var last: Long? = null

    /** [nowMs] is any monotonic clock. */
    fun accept(nowMs: Long): Boolean {
        val l = last
        if (l != null && nowMs - l in 0 until windowMs) return false
        last = nowMs
        return true
    }

    fun reset() { last = null }
}
