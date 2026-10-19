package com.anil.alfred.audio.core

/**
 * Backoff for rejoining with a fresh token once LiveKit gives up resuming a dropped room. Retries for as long as the
 * session is wanted; a network change skips the wait (VoiceSession).
 */
class ReconnectPolicy(
    val delaysMs: List<Long> = listOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000),
    /** Random extra fraction of each delay, so devices don't retry in step. */
    val jitter: Double = 0.2,
) {
    /** [attempt] counts from 1; [random] is in 0 until 1. */
    fun delayMs(attempt: Int, random: Double = Math.random()): Long {
        val last = delaysMs.lastOrNull() ?: return 0
        val base = if (attempt in 1..delaysMs.size) delaysMs[attempt - 1] else last
        return base + (base * jitter * random.coerceIn(0.0, 1.0)).toLong()
    }
}

enum class DisconnectCause {
    CLIENT_INITIATED,  // we left
    AGENT_LEFT,  // Alfred ended the session
    NETWORK,  // the connection was lost
    REMOVED,  // the server removed us, deleted the room or shut down
    DUPLICATE_IDENTITY,
    UNKNOWN;

    /** Only when nobody meant it to end. */
    val shouldReconnect: Boolean get() = this == NETWORK || this == UNKNOWN
}
