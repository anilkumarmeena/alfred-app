package com.anil.jarvis.audio.core

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * The JARVIS web app's address, as typed on the first-run page: `mac.tailnet.ts.net`,
 * `https://mac.tailnet.ts.net/`, `http://10.0.2.2:8787`. Reduced to its origin, since the page lives at `/`.
 * The same rules as the iOS side's ServerAddress.swift.
 */
class ServerAddress private constructor(val origin: String, val host: String, val isCleartext: Boolean) {

    sealed class Problem(message: String) : IllegalArgumentException(message) {
        object Empty : Problem("Enter JARVIS's address.")
        class UnsupportedScheme(val scheme: String) : Problem("$scheme:// isn't a web address. Use https://.")
        object NoHost : Problem("That doesn't look like an address. Try https://your-mac.your-tailnet.ts.net.")
    }

    /** jarvis.web's token endpoint: POST {"passcode", "device"} → {"token", "url"}. */
    val tokenUrl: String get() = "$origin/api/token"

    override fun equals(other: Any?) = other is ServerAddress && other.origin == origin
    override fun hashCode() = origin.hashCode()
    override fun toString() = origin

    companion object {
        @JvmStatic
        fun parse(text: String): ServerAddress {
            var s = text.trim()
            if (s.isEmpty()) throw Problem.Empty
            if (!s.contains("://")) s = "https://$s"  // Tailscale Serve is HTTPS
            val uri = try { URI(s) } catch (e: URISyntaxException) { throw Problem.NoHost }
            val scheme = (uri.scheme ?: "").lowercase(Locale.ROOT)
            if (scheme != "https" && scheme != "http") throw Problem.UnsupportedScheme(scheme)
            val host = uri.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: throw Problem.NoHost
            val port = uri.port.takeUnless { it == -1 || (scheme == "https" && it == 443) || (scheme == "http" && it == 80) }
            val authority = if (host.contains(':')) "[$host]" else host  // IPv6
            return ServerAddress("$scheme://$authority${port?.let { ":$it" } ?: ""}", host, scheme == "http")
        }

        /** parse(), or null for anything it refuses. */
        @JvmStatic
        fun parseOrNull(text: String?): ServerAddress? = text?.let { runCatching { parse(it) }.getOrNull() }
    }
}
