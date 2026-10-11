package com.anil.jarvis.audio.core

import java.net.URI
import java.net.URISyntaxException
import java.net.URLEncoder
import java.util.Locale

/**
 * The JARVIS address typed on the first-run page (`mac.tailnet.ts.net`, `http://10.0.2.2:8787`…), reduced to its
 * origin. Same rules as iOS ServerAddress.swift.
 */
class ServerAddress private constructor(val origin: String, val host: String, val isCleartext: Boolean) {

    sealed class Problem(message: String) : IllegalArgumentException(message) {
        object Empty : Problem("Enter JARVIS's address.")
        class UnsupportedScheme(val scheme: String) : Problem("$scheme:// isn't a web address. Use https://.")
        object NoHost : Problem("That doesn't look like an address. Try https://your-computer.your-tailnet.ts.net.")
    }

    /** POST {"passcode", "device"} → {"token", "url"}. */
    val tokenUrl: String get() = "$origin/api/token"

    /** POST {"passcode", "device", "token", "service", "topic"}. */
    val pushUrl: String get() = "$origin/api/push/native"

    /**
     * A tapped notification's page on this server, with title and body in the # as the service worker puts them.
     * Null for any other origin, so a notification can't point the web view elsewhere.
     */
    fun page(url: String, title: String? = null, body: String? = null): String? {
        val base = URI(origin)
        val resolved = try { base.resolve(url.trim()) } catch (e: IllegalArgumentException) { return null }
        if (resolved.scheme?.lowercase(Locale.ROOT) != base.scheme) return null
        if (resolved.host?.lowercase(Locale.ROOT) != host || resolved.port != base.port) return null
        val items = listOf("title" to title, "body" to body).mapNotNull { (k, v) -> v?.let { "$k=${formEncode(it)}" } }
        if (items.isEmpty()) return resolved.toString()
        val rest = resolved.toString().substringBefore('#')
        return "$rest#${items.joinToString("&")}"
    }

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

        @JvmStatic
        fun parseOrNull(text: String?): ServerAddress? = text?.let { runCatching { parse(it) }.getOrNull() }

        // The page reads the # with URLSearchParams, where + means space.
        private fun formEncode(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
    }
}
