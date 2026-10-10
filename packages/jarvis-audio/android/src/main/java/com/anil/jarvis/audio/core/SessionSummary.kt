package com.anil.jarvis.audio.core

/**
 * What the session is doing, in a word for the user: the ongoing notification (and Android 16's Live Update chip)
 * shows it under "JARVIS". Built from VoiceSession's state, so every surface outside the page says the same.
 * The same rules as the iOS side's SessionSummary.swift, which the Live Activity shows.
 */
data class SessionSummary(val phase: Phase, val muted: Boolean) {
    enum class Phase { CONNECTING, RECONNECTING, INTERRUPTED, MUTED, SPEAKING, THINKING, LISTENING }

    val status: String get() = when (phase) {
        Phase.CONNECTING -> "Connecting…"
        Phase.RECONNECTING -> "Reconnecting…"
        Phase.INTERRUPTED -> "Mic paused for a call"
        Phase.MUTED -> "Muted"
        Phase.SPEAKING -> "Speaking"
        Phase.THINKING -> "Thinking"
        Phase.LISTENING -> "Listening"
    }

    companion object {
        /**
         * [connection] and [agentState] as VoiceSession keeps them ("connecting", "reconnecting", "connected"…; an
         * lk.agent.state value or null). Null with no session.
         */
        @JvmStatic
        fun of(active: Boolean, connection: String, agentState: String?, muted: Boolean, interrupted: Boolean): SessionSummary? {
            if (!active) return null
            val phase = when {
                connection == "connecting" -> Phase.CONNECTING
                connection == "reconnecting" -> Phase.RECONNECTING
                interrupted -> Phase.INTERRUPTED
                muted -> Phase.MUTED
                agentState == "speaking" -> Phase.SPEAKING
                agentState == "thinking" -> Phase.THINKING
                else -> Phase.LISTENING
            }
            return SessionSummary(phase, muted)
        }
    }
}
