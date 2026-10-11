package com.anil.jarvis.audio.core

import java.util.Locale

object AgentStates {
    val known = setOf("initializing", "idle", "listening", "thinking", "speaking")

    @JvmStatic
    fun parse(value: String?): String? = value?.trim()?.lowercase(Locale.ROOT)?.takeIf { it in known }
}

/**
 * Accumulates lk.transcription chunks so the page always gets the whole line so far. A segment sent again starts
 * over, as on the page.
 */
class Captions(private val limit: Int = 100) {
    data class Line(val id: String, val speaker: String, val text: String, val final: Boolean)

    private val texts = LinkedHashMap<String, String>()

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
        /** Our own identity is the user; anyone else is JARVIS. Same test as the page. */
        @JvmStatic
        fun speaker(sender: String?, local: String?): String = if (sender != null && sender == local) "you" else "jarvis"
    }
}
