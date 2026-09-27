package com.anil.jarvis.audio.core

import java.util.Locale

/** The agent's lk.agent.state attribute, checked against the states the page knows. */
object AgentStates {
    val known = setOf("initializing", "idle", "listening", "thinking", "speaking")

    @JvmStatic
    fun parse(value: String?): String? = value?.trim()?.lowercase(Locale.ROOT)?.takeIf { it in known }
}

/**
 * Captions as they stream in on lk.transcription: a segment's text arrives in chunks, and the page gets the
 * whole line so far each time. A segment sent again starts over, as the page does it.
 */
class Captions(private val limit: Int = 100) {
    data class Line(val id: String, val speaker: String, val text: String, val final: Boolean)

    private val texts = LinkedHashMap<String, String>()

    /** A stream opened for segment [id]: empties the line if it was seen before. */
    fun begin(id: String) {
        texts[id] = ""
        while (texts.size > limit) texts.remove(texts.keys.first())
    }

    fun append(id: String, chunk: String, speaker: String, final: Boolean = false): Line {
        if (id !in texts) begin(id)
        val text = texts[id].orEmpty() + chunk
        texts[id] = text
        return Line(id, speaker, text, final)
    }

    fun text(id: String): String? = texts[id]

    companion object {
        /** Who said it: our own identity is the user, anyone else (the agent) is JARVIS. The same test as the page. */
        @JvmStatic
        fun speaker(sender: String?, local: String?): String = if (sender != null && sender == local) "you" else "jarvis"
    }
}
