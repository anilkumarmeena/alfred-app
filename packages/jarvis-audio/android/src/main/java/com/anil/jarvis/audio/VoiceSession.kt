package com.anil.jarvis.audio

import android.content.Context
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.anil.jarvis.audio.core.AgentStates
import com.anil.jarvis.audio.core.Captions
import com.anil.jarvis.audio.core.DisconnectCause
import com.anil.jarvis.audio.core.EarphoneDebouncer
import com.anil.jarvis.audio.core.Grant
import com.anil.jarvis.audio.core.MicSync
import com.anil.jarvis.audio.core.ReconnectPolicy
import com.anil.jarvis.audio.core.ServerAddress
import com.anil.jarvis.audio.core.SessionSummary
import com.anil.jarvis.audio.core.TokenError
import com.anil.jarvis.audio.core.TokenReply
import com.getcapacitor.JSObject
import io.livekit.android.AudioOptions
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.audio.AudioSwitchHandler
import io.livekit.android.events.DisconnectReason
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.datastream.StreamTextOptions
import io.livekit.android.room.datastream.incoming.TextStreamReceiver
import io.livekit.android.room.participant.ConnectionQuality
import io.livekit.android.room.participant.LocalParticipant
import io.livekit.android.room.participant.Participant
import io.livekit.android.room.track.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.concurrent.CopyOnWriteArraySet

/**
 * JARVIS's voice session, run natively: the same LiveKit room the page would join (a token from jarvis.web's
 * /api/token, then the agent's room), with the mic, JARVIS's voice, captions, agent state and typed messages.
 * It lives in the process, not the activity, and [VoiceService] keeps the process in the foreground while a
 * session is wanted, so the mic keeps going with the screen off. The plugin forwards what happens to the page.
 *
 * Everything here runs on the main thread.
 */
object VoiceSession {
    private const val TAG = "JarvisAudio"
    private const val TRANSCRIPTION = "lk.transcription"
    private const val CHAT = "lk.chat"
    private const val AGENT_STATE = "lk.agent.state"
    private const val SEGMENT_ID = "lk.segment_id"
    private const val LEVELS_MS = 100L

    fun interface Listener { fun onEvent(name: String, data: JSObject) }

    /** A failure the page is told about, with one of the codes in the plugin's TypeScript definitions. */
    class Failure(val code: String, message: String, val retryable: Boolean = false) : Exception(message)

    private data class Wanted(val server: ServerAddress, val passcode: String, val device: String)

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val listeners = CopyOnWriteArraySet<Listener>()
    private lateinit var app: Context

    // What the session should be: set from start() until it ends. `generation` changes whenever it does, so
    // work begun for an older session (a token fetch, a retry) drops its result.
    private var wanted: Wanted? = null
    private var generation = 0

    private var room: Room? = null
    private var roomJob: Job? = null
    private var leaving: DisconnectCause? = null  // set when the agent left, so the room ending isn't retried
    private val outbox = ArrayDeque<String>()
    private var captions = Captions()
    private val policy = ReconnectPolicy()
    private var attempt = 0
    private var retryJob: Job? = null
    private var levelsJob: Job? = null
    private var network: ConnectivityManager.NetworkCallback? = null
    private val presses = EarphoneDebouncer()
    private var sync = MicSync()  // keeps the mic track and the mute / interruption the page shows in step
    private var switching = 0  // mic track switches in flight: the room's reports of them aren't news

    var connection = "disconnected"; private set
    var agentState: String? = null; private set
    var muted = false; private set
    var interrupted = false; private set  // a call or another app has the mic for now
    var startedAt: Long? = null; private set
    var route: String? = null; private set
    val active: Boolean get() = wanted != null
    private val agentReady: Boolean get() = agentState != null && agentState != "initializing"  // lk.chat reaches it

    /** The app is on screen: only then are voice levels worth sending. Set by the plugin. */
    var foreground = true
        set(value) {
            field = value
            if (value) { takeAudioBack("app active"); startLevels() }
        }

    fun addListener(l: Listener) { listeners.add(l) }
    fun removeListener(l: Listener) { listeners.remove(l) }

    private fun emit(name: String, data: JSObject) = listeners.forEach { it.onEvent(name, data) }

    fun status(): JSObject = JSObject().apply {
        put("connection", connection)
        agentState?.let { put("agent", it) }
        put("muted", muted)
        put("interrupted", interrupted)
        startedAt?.let { put("startedAt", it) }
        route?.let { put("route", it) }
    }

    // --- Starting and ending ---

    /** Joins, or re-reports a session that's already running with the same settings (the page reloaded). */
    suspend fun start(context: Context, server: ServerAddress, passcode: String, device: String, startMuted: Boolean): JSObject {
        app = context.applicationContext
        val w = Wanted(server, passcode, device)
        if (wanted == w && connection != "disconnected") return status()
        if (wanted != null) end("hangup", null, quiet = true)
        wanted = w
        val gen = ++generation
        muted = startMuted
        sync = MicSync()
        VoiceService.start(app)  // now, while the app is in the foreground, as Android 14 requires for the mic
        watchNetwork()
        try {
            join(gen, first = true)
        } catch (f: Failure) {
            if (gen == generation) end(reasonFor(f.code), f.message)
            throw f
        }
        return status()
    }

    fun stop() {
        if (wanted == null) return
        end("hangup", null)
    }

    /** Back to no session: leave the room, stop retrying, let the service go. */
    private fun end(reason: String, message: String?, quiet: Boolean = false) {
        wanted = null
        generation++
        retryJob?.cancel(); retryJob = null
        levelsJob?.cancel(); levelsJob = null
        room?.let { dropRoom(it) }
        unwatchNetwork()
        connection = "disconnected"; agentState = null; muted = false; interrupted = false; startedAt = null
        attempt = 0; outbox.clear()
        presses.reset()
        if (::app.isInitialized) VoiceService.stop(app)
        if (!quiet) emit("connection", JSObject().apply {
            put("state", "disconnected"); put("reason", reason); message?.let { put("message", it) }
        })
    }

    private fun dropRoom(r: Room) {
        if (room === r) room = null
        roomJob?.cancel(); roomJob = null
        try { r.disconnect() } catch (e: Exception) { Log.w(TAG, "disconnect", e) }
        try { r.release() } catch (e: Exception) { Log.w(TAG, "release", e) }
    }

    private fun reasonFor(code: String) = when (code) {
        "UNAUTHORIZED" -> "unauthorized"
        "RATE_LIMITED" -> "rateLimited"
        "NO_MICROPHONE" -> "microphone"
        else -> "server"
    }

    // --- Joining ---

    private suspend fun join(gen: Int, first: Boolean) {
        val w = wanted ?: return
        setConnection(if (first) "connecting" else "reconnecting", if (first) null else "network")
        val grant = fetchToken(w)
        if (gen != generation) return

        val audio = AudioSwitchHandler(app)
        audio.registerOnAudioFocusChangeListener { change -> main.post { focusChanged(change) } }
        audio.registerAudioDeviceChangeListener { _, selected -> main.post { routeChanged(selected?.name) } }
        val r = LiveKit.create(app, overrides = LiveKitOverrides(audioOptions = AudioOptions(audioHandler = audio)))
        room = r; leaving = null; agentState = null; captions = Captions()
        roomJob = scope.launch { r.events.collect { onRoomEvent(r, it) } }
        r.registerTextStreamHandler(TRANSCRIPTION) { reader, from -> scope.launch { caption(r, reader, from.value) } }

        try {
            r.connect(grant.url, grant.token)
        } catch (e: Exception) {
            if (room === r) dropRoom(r)
            throw Failure("SERVER", "Couldn't join the session: ${e.message ?: e}", retryable = true)
        }
        if (gen != generation || room !== r) return
        for (p in r.remoteParticipants.values) if (p.kind == Participant.Kind.AGENT) agentChanged(p.attributes[AGENT_STATE])  // there before us
        if (!muted && !interrupted && !micOn(r, true)) {
            throw Failure("NO_MICROPHONE", "The microphone couldn't start. Allow it for JARVIS in Settings, then try again.")
        }
        attempt = 0
        if (startedAt == null) startedAt = System.currentTimeMillis()
        setConnection("connected", null)
        startLevels()
        applyMic()  // a mute or a call while it joined
    }

    private suspend fun fetchToken(w: Wanted): Grant {
        val (status, json) = try {
            Http.post(w.server.tokenUrl, mapOf("passcode" to w.passcode, "device" to w.device))
        } catch (e: IOException) {
            throw Failure("SERVER", "Couldn't reach JARVIS at ${w.server.host}.", retryable = true)
        }
        return TokenReply.parse(status) { Http.field(json, it) }.getOrElse { e ->
            val t = e as TokenError
            throw Failure(t.code, t.message, t.isRetryable)
        }
    }

    private suspend fun micOn(r: Room, on: Boolean): Boolean =
        try { r.localParticipant.setMicrophoneEnabled(on) } catch (e: Exception) { Log.w(TAG, "mic $on", e); false }

    // --- The room ---

    private fun onRoomEvent(r: Room, e: RoomEvent) {
        if (room !== r) return
        when (e) {
            is RoomEvent.Reconnecting -> setConnection("reconnecting", "network")
            is RoomEvent.Reconnected -> {
                setConnection("connected", null)
                scope.launch { applyMic() }  // a mute or a call while it was reconnecting
            }
            is RoomEvent.ActiveSpeakersChanged ->
                if (e.speakers.any { it is LocalParticipant } && sync.heardWhileOff(SystemClock.elapsedRealtime(), muted, interrupted)) {
                    Log.i(TAG, "mic heard while off: switching it off again")
                    scope.launch { applyMic(force = true) }
                }
            is RoomEvent.TrackMuted -> if (e.participant is LocalParticipant && e.publication.source == Track.Source.MICROPHONE) trackMuteChanged(true)
            is RoomEvent.TrackUnmuted -> if (e.participant is LocalParticipant && e.publication.source == Track.Source.MICROPHONE) trackMuteChanged(false)
            is RoomEvent.Disconnected -> roomLost(r, e.reason)
            is RoomEvent.ParticipantConnected ->
                if (e.participant.kind == Participant.Kind.AGENT) agentChanged(e.participant.attributes[AGENT_STATE])
            is RoomEvent.ParticipantAttributesChanged ->
                if (e.changedAttributes.containsKey(AGENT_STATE)) agentChanged(e.changedAttributes[AGENT_STATE])
            is RoomEvent.ParticipantDisconnected -> if (e.participant.kind == Participant.Kind.AGENT) {
                leaving = DisconnectCause.AGENT_LEFT
                r.disconnect()
            }
            is RoomEvent.ConnectionQualityChanged -> if (e.participant === r.localParticipant) {
                emit("quality", JSObject().put("quality", quality(e.quality)))
            }
            else -> {}
        }
    }

    private fun roomLost(r: Room, reason: DisconnectReason) {
        val cause = leaving ?: when (reason) {
            DisconnectReason.CLIENT_INITIATED -> DisconnectCause.CLIENT_INITIATED
            DisconnectReason.DUPLICATE_IDENTITY -> DisconnectCause.DUPLICATE_IDENTITY
            DisconnectReason.PARTICIPANT_REMOVED, DisconnectReason.ROOM_DELETED, DisconnectReason.ROOM_CLOSED,
            DisconnectReason.SERVER_SHUTDOWN -> DisconnectCause.REMOVED
            DisconnectReason.UNKNOWN_REASON -> DisconnectCause.UNKNOWN
            else -> DisconnectCause.NETWORK
        }
        Log.i(TAG, "room ended: $reason → $cause")
        dropRoom(r)
        if (wanted != null && cause.shouldReconnect) return retryLater()
        when (cause) {
            DisconnectCause.AGENT_LEFT -> end("agentLeft", "JARVIS ended the session. Tap the core to reconnect.")
            DisconnectCause.CLIENT_INITIATED -> end("hangup", null)
            else -> end("server", "The session was closed on the Mac. Tap the core to reconnect.")
        }
    }

    // --- Reconnecting: a fresh token and a fresh room, until it works or the session is no longer wanted ---

    private fun retryLater() {
        attempt++
        val wait = policy.delayMs(attempt)
        setConnection("reconnecting", "network", wait)
        val gen = generation
        retryJob?.cancel()
        retryJob = scope.launch {
            delay(wait)
            retryNow(gen)
        }
    }

    private suspend fun retryNow(gen: Int) {
        if (gen != generation || wanted == null || room != null) return
        try {
            join(gen, first = false)
        } catch (f: Failure) {
            if (gen != generation) return
            if (f.retryable) retryLater() else end(reasonFor(f.code), f.message)
        }
    }

    private fun watchNetwork() {
        if (network != null) return
        val cm = app.getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) {
                main.post {  // back online while waiting to retry: go now
                    val job = retryJob ?: return@post
                    if (!job.isActive || room != null) return@post
                    job.cancel()
                    val gen = generation
                    retryJob = scope.launch { retryNow(gen) }
                }
            }
        }
        try { cm.registerDefaultNetworkCallback(cb); network = cb } catch (e: Exception) { Log.w(TAG, "network callback", e) }
    }

    private fun unwatchNetwork() {
        val cb = network ?: return
        network = null
        try { app.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) } catch (_: Exception) {}
    }

    private fun setConnection(state: String, reason: String?, retryIn: Long? = null) {
        connection = state
        emit("connection", JSObject().apply {
            put("state", state)
            reason?.let { put("reason", it) }
            if (state == "reconnecting" && attempt > 0) put("attempt", attempt)
            retryIn?.let { put("retryIn", it) }
        })
        if (state == "connected") flush()
        VoiceService.update()
    }

    // --- The agent, captions and typed messages ---

    private fun agentChanged(value: String?) {
        val state = AgentStates.parse(value) ?: return
        agentState = state
        emit("agentState", JSObject().put("state", state))
        flush()
        VoiceService.update()
    }

    private suspend fun caption(r: Room, reader: TextStreamReceiver, from: String) {
        val id = reader.info.attributes[SEGMENT_ID] ?: reader.info.id
        val speaker = Captions.speaker(from, r.localParticipant.identity?.value)
        captions.begin(id)
        try {
            reader.flow.collect { chunk -> if (room === r) sendLine(captions.append(id, chunk, speaker)) }
        } catch (e: Exception) { Log.w(TAG, "caption $id", e) }
        if (room === r) sendLine(captions.append(id, "", speaker, final = true))
    }

    private fun sendLine(l: Captions.Line) = emit("transcript", JSObject().apply {
        put("id", l.id); put("speaker", l.speaker); put("text", l.text); put("final", l.final)
    })

    fun sendText(text: String) {
        if (wanted == null) throw Failure("NOT_CONNECTED", "No session is running.")
        outbox.addLast(text)
        flush()
    }

    private fun flush() {
        val r = room ?: return
        while (agentReady && connection == "connected" && outbox.isNotEmpty()) {
            val text = outbox.removeFirst()
            scope.launch {
                r.localParticipant.sendText(text, StreamTextOptions(topic = CHAT)).onFailure { Log.w(TAG, "lk.chat", it) }
            }
        }
    }

    // --- The mic ---

    suspend fun setMuted(m: Boolean, source: String): Boolean {
        if (wanted == null) throw Failure("NOT_CONNECTED", "No session is running.")
        muted = m
        sync.changed(SystemClock.elapsedRealtime())
        // Unmuting from the screen while "Mic paused": if no phone call holds the audio any more, that's over.
        if (!m && interrupted && source == "user") takeAudioBack("unmuted")
        // The track follows now. With no room yet (reconnecting), join and Reconnected apply it; with a call
        // holding the mic it stays off until the call is over.
        val opened = applyMic()
        if (!opened && !m) {
            muted = true  // couldn't open the mic: stay muted and say so
            sync.changed(SystemClock.elapsedRealtime())
            emit("mute", JSObject().put("muted", true).put("source", "system"))
            VoiceService.update()
            throw Failure("NO_MICROPHONE", "The microphone couldn't start.")
        }
        emit("mute", JSObject().put("muted", m).put("source", source))
        VoiceService.update()
        return m
    }

    /**
     * Switches the mic track to what the page shows ([MicSync.target]): after every mute, interruption and
     * (re)connect, so a mute made while reconnecting still stops the mic. [force] switches it even when LiveKit
     * says it's already that way. False if the track couldn't be switched.
     */
    private suspend fun applyMic(force: Boolean = false): Boolean {
        val r = room ?: return true
        if (connection != "connected") return true  // join and Reconnected apply it
        val on = MicSync.target(muted, interrupted)
        if (!force && r.localParticipant.isMicrophoneEnabled == on) return true
        switching++
        val ok = try { micOn(r, on) } finally { switching-- }
        // The mute or the interruption changed while it switched: catch up.
        if (ok && room === r && MicSync.target(muted, interrupted) != on) return applyMic()
        return ok
    }

    /**
     * LiveKit muted or unmuted the mic track. Switches made here are no news; any other (the server muting the
     * track, or LiveKit stopping a mic that failed) is followed, so the page never says Listening while nothing is
     * sent, and a track that comes back on while it should be off is switched off again.
     */
    private fun trackMuteChanged(isMuted: Boolean) {
        if (switching > 0 || connection != "connected" || !sync.settled(SystemClock.elapsedRealtime())) return
        val on = MicSync.target(muted, interrupted)
        if (!isMuted && !on) {
            Log.i(TAG, "mic track unmuted while off: switching it off again")
            scope.launch { applyMic(force = true) }
        } else if (isMuted && on) {
            Log.i(TAG, "mic track muted by the room: showing muted")
            muted = true
            sync.changed(SystemClock.elapsedRealtime())
            emit("mute", JSObject().put("muted", true).put("source", "system"))
            VoiceService.update()
        }
    }

    /** A headset button press, from [VoiceService]'s media session: a toggle, with the chime. */
    fun earphonePress() {
        if (wanted == null || !presses.accept(SystemClock.elapsedRealtime())) return
        scope.launch {
            val m = try { setMuted(!muted, "earphone") } catch (f: Failure) { return@launch }
            ChimePlayer.play(m)
        }
    }

    /**
     * A tap on the notification's Mute or Unmute (on the phone, or a watch it's mirrored to), with the chime as the
     * only sign of it off the page. It asks for a state rather than a toggle, as the iOS Live Activity does, so a
     * tap delivered twice can't undo itself: ignored when it's that way already.
     */
    fun setMutedOffPage(m: Boolean) {
        if (wanted == null || m == muted) return
        scope.launch {
            try { setMuted(m, "user") } catch (f: Failure) { return@launch }
            ChimePlayer.play(m)
        }
    }

    /** Audio focus: a phone call (transient loss) takes the mic until it's over. */
    private fun focusChanged(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> interrupt(true)
            AudioManager.AUDIOFOCUS_GAIN -> if (interrupted) interrupt(false)
            else -> Log.i(TAG, "audio focus $change")
        }
    }

    /**
     * Android doesn't promise the audio focus back after every transient loss, and one that never comes would leave
     * the page saying "Mic paused" for good. So when the app comes on screen, or the user unmutes, and no phone call
     * is ringing or going on ([MicSync.callHoldsAudio]), the interruption is over and the mic comes back.
     */
    private fun takeAudioBack(why: String) {
        if (!interrupted || wanted == null) return
        val mode = app.getSystemService(AudioManager::class.java)?.mode ?: return
        if (MicSync.callHoldsAudio(mode)) return
        Log.i(TAG, "interruption over ($why, audio mode $mode)")
        interrupt(false)
    }

    private fun interrupt(began: Boolean) {
        if (wanted == null) return
        interrupted = began
        sync.changed(SystemClock.elapsedRealtime())
        emit("interruption", JSObject().put("state", if (began) "began" else "ended"))
        scope.launch { applyMic(force = !began) }  // with no room yet, join applies it
        VoiceService.update()
    }

    private fun routeChanged(name: String?) {
        if (name == null || name == route) return
        route = name
        emit("route", JSObject().put("output", name))
    }

    private fun startLevels() {
        if (levelsJob?.isActive == true || room == null) return
        levelsJob = scope.launch {
            var sent: Pair<Double, Double>? = null
            while (isActive && foreground) {
                val r = room ?: break
                val agent = r.remoteParticipants.values.firstOrNull { it.kind == Participant.Kind.AGENT }
                val now = (if (muted) 0.0 else r.localParticipant.audioLevel.toDouble()) to (agent?.audioLevel?.toDouble() ?: 0.0)
                if (now != sent) {  // the page keeps the last levels, so repeats (mostly silence) needn't cross the bridge
                    emit("levels", JSObject().put("mic", now.first).put("agent", now.second))
                    sent = now
                }
                delay(LEVELS_MS)
            }
        }
    }

    private fun quality(q: ConnectionQuality) = when (q) {
        ConnectionQuality.EXCELLENT -> "excellent"
        ConnectionQuality.GOOD -> "good"
        ConnectionQuality.POOR -> "poor"
        ConnectionQuality.LOST -> "lost"
        else -> "unknown"
    }

    /** What the session is doing, for the notification, or null with no session. */
    val summary: SessionSummary? get() = SessionSummary.of(wanted != null, connection, agentState, muted, interrupted)
}
