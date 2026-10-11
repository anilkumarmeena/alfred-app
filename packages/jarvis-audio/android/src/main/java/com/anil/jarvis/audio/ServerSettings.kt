package com.anil.jarvis.audio

import android.app.Activity
import android.content.Context
import android.util.Log
import com.anil.jarvis.audio.core.ServerAddress
import com.getcapacitor.CapConfig
import org.json.JSONObject
import java.io.File

/**
 * Where the app loads the JARVIS page from. Capacitor reads server.url only from assets/capacitor.config.json, so
 * MainActivity passes [config], a copy with the saved address, before the bridge starts.
 */
object ServerSettings {
    private const val TAG = "JarvisAudio"
    private const val PREFS = "jarvis"
    private const val KEY_URL = "serverUrl"
    private const val KEY_SETUP = "showSetup"  // show the first-run page on next load, whatever is saved

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @JvmStatic
    fun saved(ctx: Context): ServerAddress? = ServerAddress.parseOrNull(prefs(ctx).getString(KEY_URL, null))

    /** JARVIS_SERVER_URL as of the last `npx cap sync`. */
    @JvmStatic
    fun fromBuild(ctx: Context): ServerAddress? = buildAddress(bundledConfig(ctx))

    @JvmStatic
    fun current(ctx: Context): ServerAddress? = saved(ctx) ?: fromBuild(ctx)

    @JvmStatic
    fun showingSetup(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_SETUP, false)

    @JvmStatic
    fun save(ctx: Context, address: ServerAddress) {
        prefs(ctx).edit().putString(KEY_URL, address.origin).putBoolean(KEY_SETUP, false).apply()
    }

    @JvmStatic
    fun clear(ctx: Context) {
        prefs(ctx).edit().remove(KEY_URL).putBoolean(KEY_SETUP, true).apply()
    }

    /** Shows the first-run page, with the saved address filled in, until an address is saved. */
    @JvmStatic
    fun requestSetup(ctx: Context) {
        prefs(ctx).edit().putBoolean(KEY_SETUP, true).apply()
    }

    /**
     * The bundled config with server.url set to the saved address, or removed to show the first-run page. Null
     * keeps Capacitor's default.
     */
    @JvmStatic
    fun config(activity: Activity): CapConfig? {
        val json = bundledConfig(activity) ?: return null
        val setup = prefs(activity).getBoolean(KEY_SETUP, false)
        val address = if (setup) null else saved(activity) ?: buildAddress(json)
        val server = json.optJSONObject("server") ?: JSONObject().also { json.put("server", it) }
        if (address == null) {
            server.remove("url")
        } else {
            server.put("url", address.origin)
            if (address.isCleartext) server.put("cleartext", true)
        }
        return try {
            val dir = File(activity.filesDir, "capacitor-runtime").apply { mkdirs() }
            File(dir, "capacitor.config.json").writeText(json.toString())
            CapConfig.loadFromFile(activity, dir.absolutePath)
        } catch (e: Exception) {
            Log.w(TAG, "couldn't write the runtime config, using the bundled one", e)
            null
        }
    }

    private fun buildAddress(config: JSONObject?) = ServerAddress.parseOrNull(config?.optJSONObject("server")?.optString("url"))

    private fun bundledConfig(ctx: Context): JSONObject? = try {
        ctx.assets.open("capacitor.config.json").bufferedReader().use { JSONObject(it.readText()) }
    } catch (e: Exception) {
        Log.w(TAG, "no capacitor.config.json in assets", e)
        null
    }
}
