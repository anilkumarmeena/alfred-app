package com.anil.jarvis.audio

import android.app.Activity
import android.content.Context
import android.util.Log
import com.anil.jarvis.audio.core.ServerAddress
import com.getcapacitor.CapConfig
import org.json.JSONObject
import java.io.File

/**
 * Where the app loads the JARVIS page from. Capacitor reads server.url once, from assets/capacitor.config.json,
 * so MainActivity asks [config] for a copy with the saved address put in, before the bridge starts.
 */
object ServerSettings {
    private const val TAG = "JarvisAudio"
    private const val PREFS = "jarvis"
    private const val KEY_URL = "serverUrl"
    private const val KEY_SETUP = "showSetup"  // the next launch shows the first-run page, whatever is saved

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The address saved in the app, if any. */
    @JvmStatic
    fun saved(ctx: Context): ServerAddress? = ServerAddress.parseOrNull(prefs(ctx).getString(KEY_URL, null))

    /** server.url from capacitor.config.json, i.e. JARVIS_SERVER_URL when `npx cap sync` ran. */
    @JvmStatic
    fun fromBuild(ctx: Context): ServerAddress? = buildAddress(bundledConfig(ctx))

    /** What the page loads from now: the saved address, else the build's. */
    @JvmStatic
    fun current(ctx: Context): ServerAddress? = saved(ctx) ?: fromBuild(ctx)

    @JvmStatic
    fun save(ctx: Context, address: ServerAddress) {
        prefs(ctx).edit().putString(KEY_URL, address.origin).putBoolean(KEY_SETUP, false).apply()
    }

    /** Forget the saved address and show the first-run page on the next load. */
    @JvmStatic
    fun clear(ctx: Context) {
        prefs(ctx).edit().remove(KEY_URL).putBoolean(KEY_SETUP, true).apply()
    }

    /** Show the first-run page on the next load, with the saved address filled in, until one is saved. */
    @JvmStatic
    fun requestSetup(ctx: Context) {
        prefs(ctx).edit().putBoolean(KEY_SETUP, true).apply()
    }

    /**
     * The Capacitor config to start the bridge with: the bundled one, with server.url set to the saved address
     * (Capacitor lets the page navigate within it), or removed to show the first-run page. Null keeps Capacitor's
     * default.
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
