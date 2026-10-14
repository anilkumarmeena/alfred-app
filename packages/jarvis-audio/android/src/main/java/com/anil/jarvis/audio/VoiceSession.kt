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
import com.anil.jarvis.audio.core.CallQuiet
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
import io.livekit.android.room.track.RemoteAudioTrack
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
 * The native LiveKit session the page would otherwise join. Lives in the process, not the activity, and
 * [VoiceService] keeps the process in the foreground so the mic survives the screen going off.
 *
 * Main thread only.
 */
object VoiceSession {
    private const val TAG = "JarvisAudio"
    private const val TRANSCRIPTION = "lk.transcription"
    private const val CHAT = "lk.chat"
    private const val AGENT_STATE = "lk.agent.state"
    private const val SEGMENT_ID = "lk.segment_id"
    private const val SPEAKER = "jarvis.speaker"  // "off": the agent makes no speech at all
    private const val LEVELS_MS = 100L

    fun interface Listener { fun onEvent(name: String, data: JSObject) }

    /** [code] is one of the plugin's TypeScript error codes. */
    class Failure(val code: String, message: String, val retryable: Boolean = false) : Exception(message)

    private data class Wanted(val server: ServerAddress, val passcode: String, val device: String)

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val listeners = CopyOnWriteArraySet<Listener>()
    private lateinit var app: Context

    // `generation` bumps whenever `wanted` changes, so work begun for an older session drops its result.
    private var wanted: Wanted? = null
    private var generation = 0

    private var room: Room? = null
    private var roomJob: Job? = null
    private var leaving: DisconnectCause? = null  // set when the agent left, so the disconnect isn't retried
    private val outbox = ArrayDeque<String>()
    private var captions = Captions()
    private val policy = ReconnectPolicy()
    private var attempt = 0
    private var retryJob: Job? = null
    private var levelsJob: Job? = null
    private var network: ConnectivityManager.NetworkCallback? = null
    private val presses = EarphoneDebouncer()
    private var sync = MicSync()
    private var switching = 0  // our own mic switches in flight; the room's reports of them are ignored
    private var calls: CallWatch? = null
    private var callQuiet = CallQuiet()
    private var audio: AudioSwitchHandler? = null  // the current room's: it takes audio focus and sets the mode
    private var focusWaiting = false  // started during a call, which refused the audio focus: asked again after it

    var connection = "disconnected"; private set
    var agentState: String? = null; private set
    var muted = false; private set
    /**
     * Text-only replies. The agent is told via the token and then our participant attribute; its track also plays at
     * volume 0 so a reply already being spoken stops at once.
     */
    var speakerOff = false; private set
    var interrupted = false; private set  // a call or another app holds audio focus
    var startedAt: Long? = null; private set
    var route: String? = null; private set
    val active: Boolean get() = wanted != null
    private val agentReady: Boolean get() = agentState != null && agentState != "initializing"  // lk.chat is heard

    /** Voice levels are only sent while the app is on screen. */
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
        put("speakerOff", speakerOff)
        callQuiet.offer?.let { put("afterCall", fields(it)) }
        put("interrupted", interrupted)
        startedAt?.let { put("startedAt", it) }
        route?.let { put("route", it) }
    }

    // --- Starting and ending ---

    /** Joins, or just reports status if the same session is already running (the page reloaded). */
    suspend fun start(context: Context, server: ServerAddress, passcode: String, device: String, startMuted: Boolean,
                      startSilent: Boolean = false): JSObject {
        app = context.applicationContext
        val w = Wanted(server, passcode, device)
        if (wanted == w && connection != "disconnected") return status()
        if (wanted != null) end("hangup", null, quiet = true)
        wanted = w
        val gen = ++generation
        muted = startMuted
        speakerOff = startSilent
        sync = MicSync()
        callQuiet = CallQuiet()
        if (MicSync.callHoldsAudio(app.getSystemService(AudioManager::class.java)?.mode ?: 0)) startDuringCall()
        calls = CallWatch(app) { callChanged(it) }.also { it.start() }
        VoiceService.start(app)  // while in the foreground: Android 14+ refuses a mic service started from background
        watchNetwork()
        try {
            join(gen, first = true)
        } catch (f: Failure) {
            if (gen == generation) end(reasonFor(f.code), f.message)
            throw f
        }
        // Again now it's connected: the page clears "Mic paused" when the session goes live.
        if (gen == generation && interrupted) emit("interruption", JSObject().put("state", "began"))
        return status()
    }

    fun stop() {
        if (wanted == null) return
        end("hangup", null)
    }

    private fun end(reason: String, message: String?, quiet: Boolean = false) {
        wanted = null
        generation++
        retryJob?.cancel(); retryJob = null
        levelsJob?.cancel(); levelsJob = null
        room?.let { dropRoom(it) }
        unwatchNetwork()
        calls?.stop(); calls = null
        callQuiet = CallQuiet()
        focusWaiting = false
        connection = "disconnected"; agentState = null; muted = false; speakerOff = false; interrupted = false; startedAt = null
        attempt = 0; outbox.clear()
        presses.reset()
        if (::app.isInitialized) VoiceService.stop(app)
        if (!quiet) emit("connection", JSObject().apply {
            put("state", "disconnected"); put("reason", reason); message?.let { put("message", it) }
        })
    }

    private fun dropRoom(r: Room) {
        if (room === r) { room = null; audio = null }
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

        val handler = AudioSwitchHandler(app)
        handler.registerOnAudioFocusChangeListener { change -> main.post { focusChanged(change) } }
        handler.registerAudioDeviceChangeListener { _, selected -> main.post { routeChanged(selected?.name) } }
        val r = LiveKit.create(app, overrides = LiveKitOverrides(audioOptions = AudioOptions(audioHandler = handler)))
        room = r; audio = handler; leaving = null; agentState = null; captions = Captions()
        roomJob = scope.launch { r.events.collect { onRoomEvent(r, it) } }
        r.registerTextStreamHandler(TRANSCRIPTION) { reader, from -> scope.launch { caption(r, reader, from.value) } }

        try {
            r.connect(grant.url, grant.token)
        } catch (e: Exception) {
            if (room === r) dropRoom(r)
            throw Failure("SERVER", "Couldn't join the session: ${e.message ?: e}", retryable = true)
        }
        if (gen != generation || room !== r) return
        for (p in r.remoteParticipants.values) if (p.kind == Participant.Kind.AGENT) agentChanged(p.attributes[AGENT_STATE])  // joined before us
        if (!muted && !interrupted && !micOn(r, true)) {
            throw Failure("NO_MICROPHONE", "The microphone couldn't start. Allow it for JARVIS in Settings, then try again.")
        }
        attempt = 0
        if (startedAt == null) startedAt = System.currentTimeMillis()
        setConnection("connected", null)
        startLevels()
        applyMic()  // catch up on changes made while joining
        tellSpeaker(r)
    }

    private suspend fun fetchToken(w: Wanted): Grant {
        val (status, json) = try {
            Http.post(w.server.tokenUrl, TokenReply.fields(w.passcode, w.device, speakerOff))
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
                scope.launch { applyMic() }  // catch up on changes made while reconnecting
                tellSpeaker(r)
            }
            is RoomEvent.TrackSubscribed -> if (e.track is RemoteAudioTrack) playAgent()  // silent from its first word
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
            else -> end("server", "The session was closed on the JARVIS computer. Tap the core to reconnect.")
        }
    }

    // --- Reconnecting: fresh token and room, until it works or the session is no longer wanted ---

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
                main.post {  // back online while waiting to retry: retry now
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

    private fun requireSession() {
        if (wanted == null) throw Failure("NOT_CONNECTED", "No session is running.")
    }

    fun sendText(text: String) {
        requireSession()
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
        requireSession()
        if (source != "call") callQuiet.settle()  // the user chose, so drop the after-call offer
        muted = m
        sync.changed(SystemClock.elapsedRealtime())
        if (!m && interrupted && source == "user") takeAudioBack("unmuted")
        // With no room yet, join/Reconnected apply it; during a call it stays off until the call ends.
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
     * Switches the mic track to [MicSync.target]. [force] switches even if LiveKit says it's already that way.
     * False if the track couldn't be switched.
     */
    private suspend fun applyMic(force: Boolean = false): Boolean {
        val r = room ?: return true
        if (connection != "connected") return true  // join and Reconnected apply it
        val on = MicSync.target(muted, interrupted)
        if (!force && r.localParticipant.isMicrophoneEnabled == on) return true
        switching++
        val ok = try { micOn(r, on) } finally { switching-- }
        // State changed while switching: catch up.
        if (ok && room === r && MicSync.target(muted, interrupted) != on) return applyMic()
        return ok
    }

    /**
     * Follows mic track mutes we didn't make (server mute, a failed mic) so the page never shows Listening while
     * nothing is sent, and switches off a track that comes back on while it should be off.
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

    /** A headset button press from [VoiceService]'s media session: toggles mute, with the chime. */
    fun earphonePress() {
        if (wanted == null || !presses.accept(SystemClock.elapsedRealtime())) return
        scope.launch {
            val m = try { setMuted(!muted, "earphone") } catch (f: Failure) { return@launch }
            if (!speakerOff) ChimePlayer.play(m)
        }
    }

    /**
     * The notification's Mute/Unmute (also from a mirrored watch). Sets a state rather than toggling, as the iOS Live
     * Activity does, so a tap delivered twice can't undo itself.
     */
    fun setMutedOffPage(m: Boolean) {
        if (wanted == null || m == muted) return
        scope.launch {
            try { setMuted(m, "user") } catch (f: Failure) { return@launch }
            if (!speakerOff) ChimePlayer.play(m)
        }
    }

    // --- The speaker ---

    fun setSpeaker(off: Boolean, source: String): Boolean {
        requireSession()
        if (source != "call") callQuiet.settle()
        speakerOff = off
        playAgent()
        room?.let { if (connection == "connected") tellSpeaker(it) }  // else join tells it
        emit("speaker", JSObject().put("off", off).put("source", source))
        return off
    }

    private fun tellSpeaker(r: Room) {
        val want = if (speakerOff) "off" else "on"
        if (room !== r || r.localParticipant.attributes[SPEAKER] == want) return
        try { r.localParticipant.updateAttributes(mapOf(SPEAKER to want)) } catch (e: Exception) { Log.w(TAG, "speaker $want", e) }
    }

    private fun playAgent() {
        val r = room ?: return
        for (p in r.remoteParticipants.values) {
            for ((_, track) in p.audioTrackPublications) (track as? RemoteAudioTrack)?.setVolume(if (speakerOff) 0.0 else 1.0)
        }
    }

    // --- Phone calls ---

    /** During a call the mic and speaker go off, so JARVIS neither hears it nor speaks over it ([CallQuiet]). */
    private fun callChanged(onCall: Boolean) {
        if (wanted == null) return
        if (onCall) {
            if (!callQuiet.began(current())) return
            Log.i(TAG, "a call: muting the mic and turning the speaker off")
            emit("call", JSObject().put("state", "began"))
            if (!speakerOff) setSpeaker(true, "call")
            if (!muted) scope.launch { try { setMuted(true, "call") } catch (_: Failure) {} }
        } else {
            reclaimAudio()
            val offer = callQuiet.ended(current()) ?: return
            emit("call", JSObject().put("state", "ended").put("restore", fields(offer)))
        }
    }

    /**
     * Started during a call: as a call during a session leaves it, muted with the speaker off, offered back when it
     * ends, and "Mic paused", since a phone call holds the audio (Android silences other apps' mic and refuses them
     * the audio focus). The room is still joined, so typing and captions work.
     */
    private fun startDuringCall() {
        Log.i(TAG, "starting during a call: muted, speaker off, mic paused")
        callQuiet.began(current())  // so CallWatch's first report of this call changes nothing
        muted = true
        speakerOff = true
        interrupted = true
        focusWaiting = true
        sync.changed(SystemClock.elapsedRealtime())
        emit("mute", JSObject().put("muted", true).put("source", "call"))
        emit("speaker", JSObject().put("off", true).put("source", "call"))
    }

    /**
     * The call ended: take the audio back now, rather than wait for an audio focus that never comes back to a session
     * started during the call (its request was refused), or for the app to come on screen. Restarting the room's
     * audio handler asks for the focus and the communication mode again.
     */
    private fun reclaimAudio() {
        if (focusWaiting) {
            focusWaiting = false
            audio?.let {  // with no room yet, joining asks for them
                Log.i(TAG, "call ended: asking for the audio focus again")
                try { it.stop(); it.start() } catch (e: Exception) { Log.w(TAG, "audio handler restart", e) }
            }
        }
        takeAudioBack("call ended")
    }

    suspend fun restoreAfterCall(restore: Boolean) {
        val was = callQuiet.settle() ?: return
        if (!restore) return
        if (was.speakerOff != speakerOff) try { setSpeaker(was.speakerOff, "user") } catch (_: Failure) {}
        if (was.muted != muted) try { setMuted(was.muted, "user") } catch (_: Failure) {}
    }

    private fun current() = CallQuiet.State(muted, speakerOff)

    private fun fields(s: CallQuiet.State) = JSObject().put("muted", s.muted).put("speakerOff", s.speakerOff)

    private fun focusChanged(change: Int) {
        calls?.check()  // below Android 12 the only signal of a call starting or ending
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> interrupt(true)
            AudioManager.AUDIOFOCUS_GAIN -> if (interrupted) interrupt(false)
            else -> Log.i(TAG, "audio focus $change")
        }
    }

    /**
     * Android doesn't always return audio focus after a transient loss, which would leave "Mic paused" stuck. So on
     * coming on screen or unmuting with no call holding the audio ([MicSync.callHoldsAudio]), the interruption ends.
     */
    private fun takeAudioBack(why: String) {
        calls?.check()  // a call that ended unnoticed (before Android 12, a session that never had the focus)
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
                if (now != sent) {  // the page keeps the last levels; skip repeats (mostly silence)
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

    val summary: SessionSummary? get() = SessionSummary.of(wanted != null, connection, agentState, muted, interrupted)
}
