package com.anil.jarvis.audio.core

/**
 * Registers the FCM token with jarvis.web's /api/push/native, since Web Push doesn't work in an app's web view.
 * iOS does the same with APNs (PushRegistration.swift); `service` tells JARVIS which one a token is for.
 */
object PushRegistration {
    const val SERVICE = "fcm"

    sealed class Refusal(override val message: String) : Exception(message) {
        object Unauthorized : Refusal("Wrong passcode.")
        object NotSupported : Refusal("The JARVIS computer doesn't take app notifications yet (no /api/push/native).")
        class Off(message: String) : Refusal(message)
        class Server(message: String) : Refusal(message)

        override fun equals(other: Any?) = other is Refusal && other.javaClass == javaClass && other.message == message
        override fun hashCode() = javaClass.hashCode() * 31 + message.hashCode()
    }

    /** Request body; `topic` is the package name (the bundle id on iOS). JSON is left to the caller. */
    @JvmStatic
    fun fields(passcode: String, device: String, token: String, topic: String): Map<String, String> =
        linkedMapOf("passcode" to passcode, "device" to device, "token" to token, "service" to SERVICE, "topic" to topic)

    /** [field] reads a string field of the reply's JSON object, or null if there's none (or no object). */
    @JvmStatic
    fun parse(status: Int, field: (String) -> String?): Result<Unit> {
        val said = field("error")?.takeIf { it.isNotEmpty() }
        return when (status) {
            200 -> Result.success(Unit)
            401 -> Result.failure(Refusal.Unauthorized)
            404, 405 -> Result.failure(Refusal.NotSupported)
            409 -> Result.failure(Refusal.Off(said ?: "Notifications are off on the JARVIS computer."))
            else -> Result.failure(Refusal.Server(said ?: "JARVIS didn't take the notification token (HTTP $status)."))
        }
    }
}
