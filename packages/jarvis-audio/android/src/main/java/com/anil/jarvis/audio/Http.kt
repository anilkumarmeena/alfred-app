package com.anil.jarvis.audio

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

internal object Http {
    /** The status and the reply's JSON object (null if none). Throws IOException when the JARVIS computer can't be reached. */
    suspend fun post(url: String, body: Map<String, String>): Pair<Int, JSONObject?> = withContext(Dispatchers.IO) {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 10_000; c.readTimeout = 15_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write(JSONObject(body).toString().toByteArray()) }
            val code = c.responseCode
            val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() }.orEmpty()
            code to try { JSONObject(text) } catch (e: Exception) { null }
        } finally {
            c.disconnect()
        }
    }

    fun field(json: JSONObject?, key: String): String? = json?.takeIf { it.has(key) }?.optString(key)
}
