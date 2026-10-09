package com.anil.jarvis.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class ServerAddressTest {
    @Test fun assumesHttpsAndKeepsOnlyTheOrigin() {
        assertEquals("https://mac.tailnet.ts.net", ServerAddress.parse("mac.tailnet.ts.net").origin)
        assertEquals("https://mac.tailnet.ts.net", ServerAddress.parse("  https://Mac.Tailnet.ts.net/some/path?q=1#x \n").origin)
        assertEquals("http://localhost:8787", ServerAddress.parse("http://localhost:8787/").origin)
        assertEquals("https://mac.ts.net", ServerAddress.parse("https://mac.ts.net:443").origin)
        assertEquals("https://mac.ts.net:8443", ServerAddress.parse("mac.ts.net:8443").origin)
    }

    @Test fun tokenUrl() {
        assertEquals("https://mac.ts.net/api/token", ServerAddress.parse("mac.ts.net").tokenUrl)
        assertEquals("http://10.0.2.2:8787/api/token", ServerAddress.parse("http://10.0.2.2:8787").tokenUrl)
    }

    @Test fun refusesWhatIsntAWebAddress() {
        assertThrows(ServerAddress.Problem.Empty::class.java) { ServerAddress.parse("   ") }
        val e = assertThrows(ServerAddress.Problem.UnsupportedScheme::class.java) { ServerAddress.parse("ftp://mac.ts.net") }
        assertEquals("ftp", e.scheme)
        assertThrows(ServerAddress.Problem.NoHost::class.java) { ServerAddress.parse("https://") }
        assertNull(ServerAddress.parseOrNull("https://"))
        assertNull(ServerAddress.parseOrNull(null))
    }

    @Test fun cleartext() {
        assertTrue(ServerAddress.parse("http://localhost:8787").isCleartext)
        assertFalse(ServerAddress.parse("mac.ts.net").isCleartext)
        assertEquals("mac.ts.net", ServerAddress.parse("https://MAC.ts.net/").host)
    }
}

class TokenReplyTest {
    private fun fields(vararg pairs: Pair<String, String>): (String) -> String? = mapOf(*pairs)::get

    @Test fun grant() {
        val r = TokenReply.parse(200, fields("token" to "jwt", "url" to "wss://mac.ts.net"))
        assertEquals(Grant("jwt", "wss://mac.ts.net"), r.getOrThrow())
    }

    @Test fun refusals() {
        assertEquals(TokenError.Unauthorized, TokenReply.parse(401, fields("error" to "Wrong passcode.")).exceptionOrNull())
        assertEquals(TokenError.RateLimited("Slow down."), TokenReply.parse(429, fields("error" to "Slow down.")).exceptionOrNull())
        assertEquals(TokenError.Server("Couldn't reach JARVIS (HTTP 503)."), TokenReply.parse(503, fields()).exceptionOrNull())
        assertEquals(TokenError.BadReply, TokenReply.parse(200, fields("token" to "")).exceptionOrNull())
    }

    @Test fun onlyRefusalsStopRetries() {
        assertFalse(TokenError.Unauthorized.isRetryable)
        assertFalse(TokenError.RateLimited("x").isRetryable)
        assertTrue(TokenError.Server("x").isRetryable)
        assertTrue(TokenError.BadReply.isRetryable)
    }
}

class ReconnectPolicyTest {
    @Test fun backsOffThenHolds() {
        val p = ReconnectPolicy(jitter = 0.0)
        assertEquals(listOf(1_000L, 2_000, 4_000, 8_000, 15_000, 30_000, 30_000, 30_000), (1..8).map { p.delayMs(it) })
    }

    @Test fun jitterOnlyAdds() {
        val p = ReconnectPolicy(listOf(10_000), 0.2)
        assertEquals(10_000, p.delayMs(1, 0.0))
        assertEquals(11_000, p.delayMs(1, 0.5))
        assertEquals(12_000, p.delayMs(1, 5.0))  // clamped
    }

    @Test fun onlyUnplannedEndsReconnect() {
        assertEquals(setOf(DisconnectCause.NETWORK, DisconnectCause.UNKNOWN),
            DisconnectCause.values().filter { it.shouldReconnect }.toSet())
    }
}

class EarphoneDebouncerTest {
    @Test fun onePressCountsOnce() {
        val d = EarphoneDebouncer(400)
        assertTrue(d.accept(10_000))
        assertFalse(d.accept(10_100))
        assertFalse(d.accept(10_399))
        assertTrue(d.accept(10_500))
        d.reset()
        assertTrue(d.accept(10_600))
    }

    @Test fun clockGoingBackIsANewPress() {
        val d = EarphoneDebouncer()
        assertTrue(d.accept(100_000))
        assertTrue(d.accept(5_000))
    }
}

class ChimeTest {
    @Test fun fallsForMutedRisesForListening() {
        assertEquals(listOf(880.0, 587.0), Chime.frequencies(true))
        assertEquals(listOf(587.0, 880.0), Chime.frequencies(false))
    }

    @Test fun quietShortAndFadedOut() {
        val s = Chime.samples(false, 24_000)
        assertEquals(24_000 * 19 / 100, s.size)  // 190 ms
        val peak = s.maxOf { abs(it) }
        assertTrue(peak > 0.1f && peak <= 0.16f)
        assertTrue(abs(s.last()) < 0.001f)
        assertEquals(s.size, Chime.pcm16(false, 24_000).size)
    }
}

class MicSyncTest {
    @Test fun trackFollowsTheMuteAndTheInterruption() {
        assertTrue(MicSync.target(muted = false, interrupted = false))
        assertFalse(MicSync.target(muted = true, interrupted = false))
        assertFalse(MicSync.target(muted = false, interrupted = true))
    }

    @Test fun heardWhileMutedOrPausedSwitchesItOffAgain() {
        val s = MicSync(settleMs = 2_000)
        assertTrue(s.heardWhileOff(10_000, muted = true, interrupted = false))
        assertTrue(s.heardWhileOff(10_000, muted = false, interrupted = true))
        assertFalse(s.heardWhileOff(10_000, muted = false, interrupted = false))
    }

    @Test fun reportsJustAfterAChangeAreAboutTheOldState() {
        val s = MicSync(settleMs = 2_000)
        s.changed(5_000)
        assertFalse(s.settled(6_000))
        assertFalse(s.heardWhileOff(6_000, muted = true, interrupted = false))
        assertTrue(s.settled(7_000))
    }
}

class CaptionsTest {
    @Test fun streamsWholeLines() {
        val c = Captions()
        assertEquals("Good ", c.append("s1", "Good ", "jarvis").text)
        assertEquals(Captions.Line("s1", "jarvis", "Good evening", true), c.append("s1", "evening", "jarvis", true))
    }

    @Test fun resentSegmentStartsOver() {
        val c = Captions()
        c.append("s1", "draft", "you")
        c.begin("s1")
        assertEquals("final", c.append("s1", "final", "you").text)
    }

    @Test fun forgetsOldSegments() {
        val c = Captions(2)
        listOf("a", "b", "c").forEach { c.append(it, it, "you") }
        assertNull(c.text("a"))
        assertEquals("c", c.text("c"))
    }

    @Test fun speakerAndStates() {
        assertEquals("you", Captions.speaker("anil-android-ab12", "anil-android-ab12"))
        assertEquals("jarvis", Captions.speaker("agent-AJ_x", "anil-android-ab12"))
        assertEquals("jarvis", Captions.speaker(null, null))
        assertEquals("speaking", AgentStates.parse("Speaking"))
        assertNull(AgentStates.parse("dancing"))
    }
}
