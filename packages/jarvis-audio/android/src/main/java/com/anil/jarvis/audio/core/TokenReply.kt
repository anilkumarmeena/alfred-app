package com.anil.jarvis.audio.core

/** What jarvis.web's /api/token gives back: a LiveKit token and the URL to join with it. */
data class Grant(val token: String, val url: String)

/** Why /api/token didn't give a grant. The messages are the page's own, so the app says the same things. */
sealed class TokenError(val code: String, override val message: String) : Exception(message) {
    object Unauthorized : TokenError("UNAUTHORIZED", "Wrong passcode.")
    class RateLimited(message: String) : TokenError("RATE_LIMITED", message)
    class Server(message: String) : TokenError("SERVER", message)
    object BadReply : TokenError("SERVER", "Couldn't reach JARVIS.")

    /** Worth trying again later without the user: a server hiccup, not a refusal. */
    val isRetryable: Boolean get() = this is Server || this is BadReply

    override fun equals(other: Any?) = other is TokenError && other.javaClass == javaClass && other.message == message
    override fun hashCode() = javaClass.hashCode() * 31 + message.hashCode()
}

/** The token reply. JSON is left to the caller (org.json on Android), so this runs in plain JVM tests. */
object TokenReply {
    /** The request body's fields, as the page sends them. [speakerOff]: JARVIS replies in text only, from its first word. */
    @JvmStatic
    fun fields(passcode: String, device: String, speakerOff: Boolean = false): Map<String, String> =
        mapOf("passcode" to passcode, "device" to device, "speaker" to if (speakerOff) "off" else "on")

    /** [field] reads a string field of the reply's JSON object, or null if there's none (or no object). */
    @JvmStatic
    fun parse(status: Int, field: (String) -> String?): Result<Grant> {
        val said = field("error")?.takeIf { it.isNotEmpty() }
        return when (status) {
            200 -> {
                val token = field("token").orEmpty()
                val url = field("url").orEmpty()
                if (token.isEmpty() || url.isEmpty()) Result.failure(TokenError.BadReply)
                else Result.success(Grant(token, url))
            }
            401 -> Result.failure(TokenError.Unauthorized)
            429 -> Result.failure(TokenError.RateLimited(said ?: "Too many wrong passcodes. Try again in a few minutes."))
            else -> Result.failure(TokenError.Server(said ?: "Couldn't reach JARVIS (HTTP $status)."))
        }
    }
}
