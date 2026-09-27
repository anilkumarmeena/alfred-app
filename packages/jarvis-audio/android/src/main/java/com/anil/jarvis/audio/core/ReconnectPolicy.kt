package com.anil.jarvis.audio.core

/**
 * How long to wait before each attempt to bring a lost session back. LiveKit itself resumes short drops;
 * this is for when it gives up and the room is gone: fetch a fresh token and join again. Quick at first, then
 * every half minute, for as long as the session is wanted. A network change skips the wait (VoiceSession).
 */
class ReconnectPolicy(
    val delaysMs: List<Long> = listOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000),
    /** Up to this fraction of each delay is added at random, so two devices don't retry in step. */
    val jitter: Double = 0.2,
) {
    /** The wait before attempt [attempt] (from 1). [random] is in 0 until 1. */
    fun delayMs(attempt: Int, random: Double = Math.random()): Long {
        val last = delaysMs.lastOrNull() ?: return 0
        val base = if (attempt in 1..delaysMs.size) delaysMs[attempt - 1] else last
        return base + (base * jitter * random.coerceIn(0.0, 1.0)).toLong()
    }
}

/** Why a room went away, reduced to what decides whether to rejoin it. */
enum class DisconnectCause {
    CLIENT_INITIATED,  // we left
    AGENT_LEFT,  // JARVIS ended the session
    NETWORK,  // the connection was lost
    REMOVED,  // the server removed us, deleted the room or shut down
    DUPLICATE_IDENTITY,
    UNKNOWN;

    /** Rejoin on our own? Only when nobody meant it to end. */
    val shouldReconnect: Boolean get() = this == NETWORK || this == UNKNOWN
}
