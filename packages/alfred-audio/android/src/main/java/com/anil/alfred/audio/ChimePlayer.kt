package com.anil.alfred.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.anil.alfred.audio.core.Chime

/** Plays the earphone cue on the call's route, so it comes out of the headset that was pressed. */
object ChimePlayer {
    private const val RATE = 24_000
    private val tracks = mutableMapOf<Boolean, AudioTrack>()  // one static track per cue

    fun play(muted: Boolean) {
        try {
            val track = tracks.getOrPut(muted) { build(Chime.pcm16(muted, RATE)) }
            track.stop()
            track.reloadStaticData()
            track.play()
        } catch (e: Exception) {
            Log.w("JarvisAudio", "chime", e)
        }
    }

    private fun build(pcm: ShortArray): AudioTrack = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build())
        .setAudioFormat(AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build())
        .setTransferMode(AudioTrack.MODE_STATIC)
        .setBufferSizeInBytes(pcm.size * 2)
        .build()
        .apply { write(pcm, 0, pcm.size) }
}
