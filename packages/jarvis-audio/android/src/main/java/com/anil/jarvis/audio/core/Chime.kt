package com.anil.jarvis.audio.core

import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin

/**
 * The page's earphone cue (web/src/lib/mic.ts `chime`) as PCM: falling notes for muted, rising for listening.
 * Native because the page can't play sound in the background.
 */
object Chime {
    const val HIGH = 880.0
    const val LOW = 587.0
    private const val GAP = 0.1
    private const val ATTACK = 0.01
    private const val DECAY = 0.08
    private const val LENGTH = 0.09
    private const val PEAK = 0.15
    private const val FLOOR = 0.0001

    @JvmStatic
    fun frequencies(muted: Boolean): List<Double> = if (muted) listOf(HIGH, LOW) else listOf(LOW, HIGH)

    /** Samples in -1..1, with the page's exponential ramps (10 ms in, out by 80 ms). */
    @JvmStatic
    fun samples(muted: Boolean, rate: Int = 24_000): FloatArray {
        val total = ((GAP + LENGTH) * rate).toInt()
        val out = FloatArray(total)
        frequencies(muted).forEachIndexed { i, hz ->
            val start = (i * GAP * rate).toInt()
            for (n in 0 until (LENGTH * rate).toInt()) {
                if (start + n >= total) break
                val t = n.toDouble() / rate
                val level = when {
                    t < ATTACK -> FLOOR * (PEAK / FLOOR).pow(t / ATTACK)
                    t < DECAY -> PEAK * (FLOOR / PEAK).pow((t - ATTACK) / (DECAY - ATTACK))
                    else -> 0.0
                }
                out[start + n] += (level * sin(2 * PI * hz * t)).toFloat()
            }
        }
        return out
    }

    @JvmStatic
    fun pcm16(muted: Boolean, rate: Int = 24_000): ShortArray =
        samples(muted, rate).map { (it.coerceIn(-1f, 1f) * Short.MAX_VALUE).toInt().toShort() }.toShortArray()
}
