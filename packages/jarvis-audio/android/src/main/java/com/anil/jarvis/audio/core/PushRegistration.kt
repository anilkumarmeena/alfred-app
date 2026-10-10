package com.anil.jarvis.audio.core

/**
 * The app's side of JARVIS's notifications: the FCM registration token, handed to jarvis.web's /api/push/native with
 * the passcode, so the task runner and the heartbeat can reach the phone through Firebase Cloud Messaging even when
 * the app is closed. The JARVIS page's own Web Push doesn't work in an app's web view. The iOS side does the same
 * with APNs (PushRegistration.swift); `service` tells the Mac which one a token is for.
 */
object PushRegistration {
    const val SERVICE = "fcm"

    /** Why jarvis.web didn't take the token. */
    sealed class Refusal(override val message: String) : Exception(message) {
        object Unauthorized : Refusal("Wrong passcode.")
        object NotSupported : Refusal("JARVIS on the Mac doesn't take app notifications yet (no /api/push/native).")
        class Off(message: String) : Refusal(message)
        class Server(message: String) : Refusal(message)

        override fun equals(other: Any?) = other is Refusal && other.javaClass == javaClass && other.message == message
        override fun hashCode() = javaClass.hashCode() * 31 + message.hashCode()
    }

    /**
     * The request body's fields: the same passcode and device as /api/token, the token, the push service, and the
     * app's package name (`topic`, as the bundle id is on iOS). JSON is left to the caller (org.json on Android).
     */
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
            409 -> Result.failure(Refusal.Off(said ?: "Notifications are off on the Mac."))
            else -> Result.failure(Refusal.Server(said ?: "JARVIS didn't take the notification token (HTTP $status)."))
        }
    }
}
